// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/console2.sol";
import "../TestSetup.sol";
import "../../script/deploys/Deployed.s.sol";

/// @notice Mainnet-fork tests for the MIN_AMOUNT_FOR_SHARE immutable on LiquidityPool.
///
/// MIN_AMOUNT_FOR_SHARE is enforced by `_checkMinAmountForShare()` which reverts with
/// `InvalidAmountForShare` whenever `amountForShare(1 ether) < MIN_AMOUNT_FOR_SHARE`.
/// The check is invoked from every state-changing path that can move the eETH/ETH ratio:
///   - receive(), _deposit() (deposit / depositToRecipient / deposit(address,address))
///   - withdraw() (NFT, membershipManager, redemptionManager, priorityWithdrawalQueue)
///   - rebase() (membershipManager)
///   - burnEEthShares() (redemptionManager / NFT / priorityQueue)
///   - burnEEthSharesForNonETHWithdrawal() (redemptionManager)
///   - _accountForEthSentOut() (validator funding)
///
/// These tests exercise each of those impacted entry points against real mainnet state by
/// upgrading the LiquidityPool implementation in-place to one constructed with a chosen MIN.
contract MinAmountForShareForkTest is TestSetup, Deployed {
    address internal constant ETH_ADDRESS = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    function setUp() public {
        initializeRealisticFork(MAINNET_FORK);
        // alice/bob may collide with code-bearing addresses on a live fork; clear them so
        // ETH transfers in tests aren't intercepted by an unrelated fallback.
        vm.etch(alice, bytes(""));
        vm.etch(bob, bytes(""));
    }

    // ---------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------

    /// @dev Deploy a fresh LiquidityPool implementation with the desired MIN and upgrade
    /// the proxy. The `priorityWithdrawalQueue` immutable on mainnet is `address(0)` today;
    /// preserve that so we don't introduce unrelated changes through the fork upgrade.
    function _upgradeLpWithMinAmount(uint256 minAmount) internal {
        LiquidityPool newImpl = new LiquidityPool(address(0), minAmount);
        vm.prank(roleRegistryInstance.owner());
        liquidityPoolInstance.upgradeTo(address(newImpl));
        assertEq(liquidityPoolInstance.MIN_AMOUNT_FOR_SHARE(), minAmount);
    }

    function _ratio() internal view returns (uint256) {
        return liquidityPoolInstance.amountForShare(1 ether);
    }

    /// @dev Wire the redemption manager so a redeem call doesn't get rejected by the
    /// rate limiter or the lowWatermark on a live fork.
    function _openRedemptionManager() internal {
        vm.startPrank(OPERATING_TIMELOCK);
        etherFiRedemptionManagerInstance.setCapacity(3000 ether, ETH_ADDRESS);
        etherFiRedemptionManagerInstance.setRefillRatePerSecond(3000 ether, ETH_ADDRESS);
        etherFiRedemptionManagerInstance.setLowWatermarkInBpsOfTvl(0, ETH_ADDRESS);
        vm.stopPrank();
        vm.warp(block.timestamp + 1);
    }

    // ---------------------------------------------------------------------
    // Immutable wiring
    // ---------------------------------------------------------------------

    /// Pre-upgrade: mainnet's currently-deployed LP impl predates this branch, so the
    /// `MIN_AMOUNT_FOR_SHARE` getter selector does not exist on the deployed bytecode.
    /// The proxy delegatecall returns no data and reverts. Asserting this guards against
    /// silent regressions in the pre-upgrade baseline this test suite assumes.
    function test_fork_minAmount_getter_absent_pre_upgrade() public {
        (bool ok, ) = address(liquidityPoolInstance).staticcall(
            abi.encodeWithSignature("MIN_AMOUNT_FOR_SHARE()")
        );
        assertFalse(ok, "MIN_AMOUNT_FOR_SHARE getter unexpectedly exists pre-upgrade");
    }

    function test_fork_minAmount_immutable_set_after_upgrade() public {
        _upgradeLpWithMinAmount(0.5 ether);
        assertEq(liquidityPoolInstance.MIN_AMOUNT_FOR_SHARE(), 0.5 ether);

        _upgradeLpWithMinAmount(1.5 ether);
        assertEq(liquidityPoolInstance.MIN_AMOUNT_FOR_SHARE(), 1.5 ether);

        _upgradeLpWithMinAmount(0);
        assertEq(liquidityPoolInstance.MIN_AMOUNT_FOR_SHARE(), 0);
    }

    // ---------------------------------------------------------------------
    // deposit() — _deposit() path
    // ---------------------------------------------------------------------

    function test_fork_deposit_succeeds_when_min_below_current_ratio() public {
        uint256 ratio = _ratio();
        require(ratio > 1, "fork ratio too small");
        _upgradeLpWithMinAmount(ratio - 1);

        vm.deal(alice, 10 ether);
        vm.prank(alice);
        uint256 shares = liquidityPoolInstance.deposit{value: 1 ether}();

        assertGt(shares, 0);
        // Proportional minting preserves the ratio.
        assertEq(_ratio(), ratio);
    }

    function test_fork_deposit_succeeds_at_exact_boundary() public {
        // strict `<` lets equality through
        uint256 ratio = _ratio();
        _upgradeLpWithMinAmount(ratio);

        vm.deal(alice, 10 ether);
        vm.prank(alice);
        uint256 shares = liquidityPoolInstance.deposit{value: 1 ether}();
        assertGt(shares, 0);
    }

    function test_fork_deposit_reverts_when_min_above_current_ratio() public {
        uint256 ratio = _ratio();
        _upgradeLpWithMinAmount(ratio + 1);

        vm.deal(alice, 10 ether);
        vm.prank(alice);
        vm.expectRevert(LiquidityPool.InvalidAmountForShare.selector);
        liquidityPoolInstance.deposit{value: 1 ether}();
    }

    /// MIN much larger than any plausible ratio — every deposit must revert.
    function test_fork_deposit_reverts_when_min_extreme() public {
        _upgradeLpWithMinAmount(type(uint128).max);

        vm.deal(alice, 10 ether);
        vm.prank(alice);
        vm.expectRevert(LiquidityPool.InvalidAmountForShare.selector);
        liquidityPoolInstance.deposit{value: 1 ether}();
    }

    // ---------------------------------------------------------------------
    // receive() — bare ETH transfer to the LP
    // ---------------------------------------------------------------------

    /// receive() decrements totalValueOutOfLp by msg.value (it's the ELE sweep / restaker
    /// return path). On a fork totalValueOutOfLp is enormous, so a 1 ether send won't
    /// underflow — the only revert source we care about is `InvalidAmountForShare`.
    function test_fork_receive_reverts_when_min_above_current_ratio() public {
        uint256 ratio = _ratio();
        _upgradeLpWithMinAmount(ratio + 1);

        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (bool ok, bytes memory err) = address(liquidityPoolInstance).call{value: 1 ether}("");
        assertFalse(ok);
        // expect the InvalidAmountForShare selector specifically
        assertEq(bytes4(err), LiquidityPool.InvalidAmountForShare.selector);
    }

    function test_fork_receive_succeeds_when_min_below_current_ratio() public {
        uint256 ratio = _ratio();
        _upgradeLpWithMinAmount(ratio - 1);

        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (bool ok, ) = address(liquidityPoolInstance).call{value: 1 ether}("");
        assertTrue(ok);
    }

    // ---------------------------------------------------------------------
    // rebase()
    // ---------------------------------------------------------------------

    function test_fork_rebase_positive_succeeds_at_boundary() public {
        uint256 ratio = _ratio();
        // MIN == current ratio. A positive rebase only raises the ratio, so it must pass.
        _upgradeLpWithMinAmount(ratio);

        address mm = liquidityPoolInstance.membershipManager();
        vm.prank(mm);
        liquidityPoolInstance.rebase(int128(int256(uint256(1 ether))));

        assertGe(_ratio(), ratio);
    }

    function test_fork_rebase_negative_reverts_when_below_min() public {
        uint256 ratio = _ratio();
        _upgradeLpWithMinAmount(ratio);

        // Any meaningful negative rebase strictly reduces the ratio, which is now == MIN.
        // A 100 ether shrink against mainnet's totalShares is enough to move ratio by far
        // more than 1 wei.
        address mm = liquidityPoolInstance.membershipManager();
        vm.prank(mm);
        vm.expectRevert(LiquidityPool.InvalidAmountForShare.selector);
        liquidityPoolInstance.rebase(-100 ether);
    }

    function test_fork_rebase_negative_succeeds_when_above_min() public {
        uint256 ratio = _ratio();
        // Park MIN well below current ratio. A small negative rebase shouldn't trip it.
        require(ratio > 0.1 ether, "fork ratio too small");
        _upgradeLpWithMinAmount(ratio - 0.1 ether);

        address mm = liquidityPoolInstance.membershipManager();
        vm.prank(mm);
        liquidityPoolInstance.rebase(-100 ether);

        // ratio decreased but stayed above MIN
        uint256 newRatio = _ratio();
        assertLt(newRatio, ratio);
        assertGe(newRatio, liquidityPoolInstance.MIN_AMOUNT_FOR_SHARE());
    }

    // ---------------------------------------------------------------------
    // EtherFiRedemptionManager.redeemEEth — burnEEthSharesForNonETHWithdrawal + withdraw
    // ---------------------------------------------------------------------

    /// The exit fee retained by the protocol means a redemption can only INCREASE the
    /// ratio, so as long as MIN <= currentRatio the redeem path goes through.
    function test_fork_redemption_succeeds_when_min_at_current_ratio() public {
        _openRedemptionManager();
        uint256 ratio = _ratio();
        _upgradeLpWithMinAmount(ratio);

        vm.deal(alice, 50 ether);
        vm.startPrank(alice);
        liquidityPoolInstance.deposit{value: 30 ether}();

        address receiver = makeAddr("min-share-receiver");
        vm.etch(receiver, bytes(""));
        uint256 amount = 10 ether;
        eETHInstance.approve(address(etherFiRedemptionManagerInstance), amount);
        etherFiRedemptionManagerInstance.redeemEEth(amount, receiver, ETH_ADDRESS);
        vm.stopPrank();

        // Ratio after redemption is at or above the boundary.
        assertGe(_ratio(), ratio);
    }

    /// With MIN above the current ratio, redeemEEth reverts on the very first hop into LP.
    /// This test demonstrates the guard blocks the redemption flow end-to-end.
    function test_fork_redemption_reverts_when_min_above_current_ratio() public {
        _openRedemptionManager();
        uint256 ratio = _ratio();

        // Pre-stage: deposit BEFORE upgrading so we have eETH that bypasses the deposit guard.
        vm.deal(alice, 50 ether);
        vm.prank(alice);
        liquidityPoolInstance.deposit{value: 30 ether}();

        _upgradeLpWithMinAmount(ratio + 1);

        address receiver = makeAddr("min-share-receiver-2");
        vm.etch(receiver, bytes(""));
        uint256 amount = 10 ether;

        vm.startPrank(alice);
        eETHInstance.approve(address(etherFiRedemptionManagerInstance), amount);
        vm.expectRevert(LiquidityPool.InvalidAmountForShare.selector);
        etherFiRedemptionManagerInstance.redeemEEth(amount, receiver, ETH_ADDRESS);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------------
    // burnEEthShares — direct path used by redemptionManager / NFT / priorityQueue
    // ---------------------------------------------------------------------

    /// Burning shares (without removing pooled ETH) only RAISES the ratio — even with MIN
    /// pinned to the pre-burn ratio the call must succeed.
    function test_fork_burnEEthShares_succeeds_at_boundary() public {
        // mint some eETH to the redemption manager so it has shares to burn
        vm.deal(alice, 50 ether);
        vm.prank(alice);
        liquidityPoolInstance.deposit{value: 30 ether}();
        vm.prank(alice);
        eETHInstance.transfer(address(etherFiRedemptionManagerInstance), 5 ether);
        uint256 sharesToBurn = eETHInstance.shares(address(etherFiRedemptionManagerInstance));

        uint256 ratio = _ratio();
        _upgradeLpWithMinAmount(ratio);

        vm.prank(address(etherFiRedemptionManagerInstance));
        liquidityPoolInstance.burnEEthShares(sharesToBurn);

        // ratio increased
        assertGe(_ratio(), ratio);
    }

    // ---------------------------------------------------------------------
    // Fuzz across many MIN values vs the live mainnet ratio
    // ---------------------------------------------------------------------

    function testFuzz_fork_deposit_boundary_across_min_values(uint256 rawMin) public {
        uint256 ratio = _ratio();
        // bound MIN to a meaningful range either side of the live ratio
        uint256 minAmount = bound(rawMin, 0, ratio + 1 ether);
        _upgradeLpWithMinAmount(minAmount);

        vm.deal(alice, 10 ether);
        vm.prank(alice);
        if (ratio < minAmount) {
            vm.expectRevert(LiquidityPool.InvalidAmountForShare.selector);
            liquidityPoolInstance.deposit{value: 1 ether}();
        } else {
            uint256 shares = liquidityPoolInstance.deposit{value: 1 ether}();
            assertGt(shares, 0);
            assertEq(_ratio(), ratio);
        }
    }
}
