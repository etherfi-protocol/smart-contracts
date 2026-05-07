// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";

import "../src/Liquifier.sol";
import "../src/RoleRegistry.sol";
import "../src/UUPSProxy.sol";
import "./mocks/MockChainlinkPriceFeed.sol";

/// @dev Minimal stETH/ETH curve quoter mock. Only `get_dy` is exercised by
///      `quoteByMarketValue`; the full ICurvePool interface is not required.
contract MockCurvePool {
    uint256 public quote;

    function set(uint256 _quote) external {
        quote = _quote;
    }

    function get_dy(int128, int128, uint256) external view returns (uint256) {
        return quote;
    }
}

/// @notice Self-contained tests for the stETH chainlink price-feed sanity check
///         added in `Liquifier.quoteByMarketValue`. Runs without a fork by
///         deploying mock curve + chainlink feeds and bypassing token
///         registration (whitelisting via owner-gated setter).
contract LiquifierStEthPriceFeedTest is Test {
    Liquifier internal liquifier;
    RoleRegistry internal roleRegistry;
    MockChainlinkPriceFeed internal feed;
    MockCurvePool internal curve;

    address internal stEth = address(0xBEEF); // dummy stETH; price-feed path doesn't transfer
    address internal owner = address(0xA11CE);

    uint256 internal constant STALE_WINDOW = 1 days;
    uint256 internal constant MAX_DEVIATION_BPS = 500;
    uint256 internal constant BPS = 10_000;
    uint256 internal constant MIN_DISCOUNT = 100;

    function setUp() public {
        // Deterministic timestamp far enough in the future that we can subtract
        // arbitrary ages from it without underflow.
        vm.warp(1_700_000_000);

        RoleRegistry rrImpl = new RoleRegistry();
        UUPSProxy rrProxy = new UUPSProxy(
            address(rrImpl),
            abi.encodeWithSelector(RoleRegistry.initialize.selector, owner)
        );
        roleRegistry = RoleRegistry(address(rrProxy));

        feed = new MockChainlinkPriceFeed(int256(1 ether), block.timestamp);
        curve = new MockCurvePool();

        Liquifier impl = new Liquifier(address(roleRegistry), address(feed), MIN_DISCOUNT, STALE_WINDOW, MAX_DEVIATION_BPS);
        UUPSProxy proxy = new UUPSProxy(address(impl), "");
        liquifier = Liquifier(payable(address(proxy)));

        liquifier.initialize(
            address(0xCAFE),    // treasury
            address(0xCAFF),    // liquidityPool
            address(0xCAFFEE),  // strategyManager
            address(0xCAFFFE),  // lidoWithdrawalQueue
            stEth,
            address(curve),
            uint32(1 hours)
        );

        // updateWhitelistedToken bypasses the strategy-underlying check that
        // registerToken enforces, which lets us test against a dummy stEth.
        liquifier.updateWhitelistedToken(stEth, true);

        vm.startPrank(owner);
        roleRegistry.grantRole(liquifier.LIQUIFIER_ADMIN_ROLE(), owner);
        vm.stopPrank();

        vm.prank(owner);
        liquifier.updateQuoteStEthWithCurve(true);
    }

    // -----------------------------------------------------------------------
    // Unit tests
    // -----------------------------------------------------------------------

    /// Zero price feed should revert
    function test_invalidPriceFeed_reverts() public {
        feed.set(int256(0), block.timestamp);
        curve.set(0.5 ether);

        vm.expectRevert(Liquifier.InvalidPriceFeed.selector);
        liquifier.quoteByMarketValue(stEth, 1 ether);
    }

    /// Negative price feed should revert
    function test_negativePriceFeed_reverts() public {
        feed.set(int256(-1), block.timestamp);
        curve.set(0.5 ether);

        vm.expectRevert(Liquifier.InvalidPriceFeed.selector);
        liquifier.quoteByMarketValue(stEth, 1 ether);
    }

    /// Stale price (updatedAt + window < now): check is skipped, quote returns curve value.
    function test_stalePrice_skipsCheck() public {
        feed.set(int256(1000 ether), block.timestamp - STALE_WINDOW - 1); // arbitrarily large but stale
        curve.set(0.99 ether);

        uint256 q = liquifier.quoteByMarketValue(stEth, 1 ether);
        assertEq(q, 0.99 ether);
    }

    /// Boundary: updatedAt + window == block.timestamp counts as fresh (`>=`),
    /// so the check IS active. With a chainlink answer well above curve, this reverts.
    function test_stalenessBoundary_atExactWindow_checkActive() public {
        feed.set(int256(2 ether), block.timestamp - STALE_WINDOW);
        curve.set(0.5 ether);

        vm.expectRevert(Liquifier.InvalidStEthPrice.selector);
        liquifier.quoteByMarketValue(stEth, 1 ether);
    }

    /// Boundary: one second past the window — stale, check skipped.
    function test_stalenessBoundary_oneSecondPastWindow_skipped() public {
        feed.set(int256(2 ether), block.timestamp - STALE_WINDOW - 1);
        curve.set(0.5 ether);

        uint256 q = liquifier.quoteByMarketValue(stEth, 1 ether);
        assertEq(q, 0.5 ether);
    }

    /// Fresh price within deviation tolerance: passes. Curve says 0.99, chainlink says 1.0;
    /// deviation = 0.01 / 0.99 ≈ 101 bps, well below the 500 bps cap.
    function test_freshPrice_withinDeviation_passes() public {
        feed.set(int256(1 ether), block.timestamp);
        curve.set(0.99 ether);

        uint256 q = liquifier.quoteByMarketValue(stEth, 1 ether);
        // marketValue = min(1, 0.99) = 0.99
        assertEq(q, 0.99 ether);
    }

    /// Fresh price exactly at the 500 bps boundary. Predicate uses strict `>`, so
    /// equality must NOT revert. Setup: amount=10_500, curve=10_000, feed=1 ETH.
    /// pricefeedValue=10_500, marketValue=10_000, deviation=500 → 500*BPS/10_000 = 500 (==cap).
    function test_freshPrice_atDeviationBoundary_passes() public {
        feed.set(int256(1 ether), block.timestamp);
        curve.set(10_000);

        uint256 q = liquifier.quoteByMarketValue(stEth, 10_500);
        assertEq(q, 10_000);
    }

    /// Fresh price one unit above the 500 bps boundary: reverts. Same shape as above
    /// with amount=10_501 → deviation=501 → 501*BPS/10_000 = 501 (>cap).
    function test_freshPrice_oneAboveDeviation_reverts() public {
        feed.set(int256(1 ether), block.timestamp);
        curve.set(10_000);

        vm.expectRevert(Liquifier.InvalidStEthPrice.selector);
        liquifier.quoteByMarketValue(stEth, 10_501);
    }

    /// Curve quote above 1:1 stETH→ETH: marketValue capped at amount via _min.
    /// Chainlink at 1.0 must still pass (chainlinkValue == cap, deviation = 0).
    function test_curveAboveAmount_marketValueCappedAtAmount() public {
        feed.set(int256(1 ether), block.timestamp);
        curve.set(1.5 ether); // > amount → _min returns amount

        uint256 q = liquifier.quoteByMarketValue(stEth, 1 ether);
        assertEq(q, 1 ether);
    }

    /// quoteStEthWithCurve = false: feed and curve are not consulted at all.
    /// Wire the feed to a value that would otherwise trip the check; assert no revert.
    function test_quoteStEthWithCurveFalse_skipsFeedAndCurve() public {
        vm.prank(owner);
        liquifier.updateQuoteStEthWithCurve(false);

        feed.set(int256(1000 ether), block.timestamp); // would otherwise revert
        curve.set(0); // would otherwise dominate _min and force marketValue=0

        uint256 q = liquifier.quoteByMarketValue(stEth, 1 ether);
        assertEq(q, 1 ether); // 1:1 fallback path
    }

    // -----------------------------------------------------------------------
    // Fuzz
    // -----------------------------------------------------------------------

    /// Re-implements the on-chain decision in plain solidity and asserts the
    /// contract behavior matches across the full input domain.
    function testFuzz_priceFeedCheck(
        uint256 amount,
        uint256 curveOut,
        int256 answer,
        uint256 age
    ) public {
        // Bound to ranges that exercise the check without overflowing the
        // (uint256(answer) * amount) / 1e18 product. curveOut is bounded > 0
        // because marketValue=0 + fresh + answer>0 would div-by-zero in the
        // BPS deviation check; that's a separate concern not covered here.
        amount   = bound(amount,   1, 1_000_000 ether);
        curveOut = bound(curveOut, 1, 2_000_000 ether);
        answer   = bound(answer, 0, int256(uint256(2 ether))); // 0..2 ETH per stETH
        age      = bound(age,    0, STALE_WINDOW * 2);

        uint256 updatedAt = block.timestamp - age;
        feed.set(answer, updatedAt);
        curve.set(curveOut);

        // Mirror the contract:
        uint256 marketValue = curveOut < amount ? curveOut : amount;
        uint256 chainlinkValue = (uint256(answer) * amount) / 1e18;
        bool fresh = updatedAt + STALE_WINDOW >= block.timestamp;
        uint256 deviation = chainlinkValue > marketValue ? chainlinkValue - marketValue : marketValue - chainlinkValue;

        if (answer <= 0) {
            vm.expectRevert(Liquifier.InvalidPriceFeed.selector);
            liquifier.quoteByMarketValue(stEth, amount);
        } else if (fresh && (deviation * BPS) / marketValue > MAX_DEVIATION_BPS) {
            vm.expectRevert(Liquifier.InvalidStEthPrice.selector);
            liquifier.quoteByMarketValue(stEth, amount);
        } else {
            uint256 q = liquifier.quoteByMarketValue(stEth, amount);
            assertEq(q, marketValue);
        }
    }
}
