// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "../TestSetup.sol";
import "../../src/Liquifier.sol";

/// @notice Mainnet-fork tests scoped narrowly to the stETH price-feed sanity
///         check in `Liquifier.quoteByMarketValue`. Confirms the upgraded
///         Liquifier is wired to the live Chainlink stETH/ETH aggregator,
///         exercises the happy path against live data, and uses `vm.mockCall`
///         to drive the feed into adversarial / stale states.
///
/// Requires MAINNET_RPC_URL.
contract LiquifierStEthPriceFeedForkTest is TestSetup {
    address constant CHAINLINK_STETH_ETH_FEED = 0x86392dC19c0b719886221c78AB11eb8Cf5c52812;

    function setUp() public {
        initializeRealisticFork(MAINNET_FORK);
        setUpLiquifier(MAINNET_FORK);

        // The price-feed branch only fires when curve-based quoting is enabled.
        vm.prank(owner);
        liquifierInstance.updateQuoteStEthWithCurve(true);
    }

    // -----------------------------------------------------------------------
    // Wiring sanity
    // -----------------------------------------------------------------------

    function test_immutables_pointAtLiveChainlinkFeed() public view {
        assertEq(address(liquifierInstance.stEthPriceFeed()), CHAINLINK_STETH_ETH_FEED);
        assertEq(liquifierInstance.STALE_PRICE_WINDOW(), 24 hours);
        assertEq(liquifierInstance.MAX_OFF_CHAIN_PREMIUM(), 0.01 ether);
    }

    function test_liveFeed_returnsFreshAnswer() public view {
        (, int256 answer, , uint256 updatedAt,) =
            AggregatorV3Interface(CHAINLINK_STETH_ETH_FEED).latestRoundData();

        assertGt(answer, 0, "feed should report positive stETH/ETH price");
        // Use a generous window: stETH/ETH heartbeat is ~24h. We don't want this
        // assertion to flake when the fork lands moments after a heartbeat tick.
        assertGe(updatedAt + 48 hours, block.timestamp, "feed reasonably fresh");
    }

    // -----------------------------------------------------------------------
    // Happy path: live curve quote vs. live chainlink answer
    // -----------------------------------------------------------------------

    function test_quoteByMarketValue_passesWithLiveData() public view {
        uint256 q = liquifierInstance.quoteByMarketValue(address(stEth), 1 ether);
        // stETH is roughly 1 ETH; curve quote can be slightly under par, never above.
        assertLe(q, 1 ether, "marketValue capped at amount via _min");
        assertGt(q, 0.95 ether, "live curve should quote close to par");
    }

    // -----------------------------------------------------------------------
    // Adversarial: mocked feed forces revert
    // -----------------------------------------------------------------------

    /// Mocked fresh chainlink answer well above the live curve quote + premium → revert.
    function test_quoteByMarketValue_revertsOnMockedAbovePremium() public {
        _mockChainlinkAnswer(int256(1.5 ether), block.timestamp);

        vm.expectRevert(Liquifier.InvalidStEthPrice.selector);
        liquifierInstance.quoteByMarketValue(address(stEth), 1 ether);
    }

    /// Boundary: updatedAt + window == now still counts as fresh (`>=`).
    function test_quoteByMarketValue_atStalenessBoundary_checkActive() public {
        uint256 staleWindow = liquifierInstance.STALE_PRICE_WINDOW();
        _mockChainlinkAnswer(int256(100 ether), block.timestamp - staleWindow);

        vm.expectRevert(Liquifier.InvalidStEthPrice.selector);
        liquifierInstance.quoteByMarketValue(address(stEth), 1 ether);
    }

    // -----------------------------------------------------------------------
    // Skip path: mocked stale feed bypasses the check
    // -----------------------------------------------------------------------

    function test_quoteByMarketValue_skipsCheckOnMockedStaleFeed() public {
        uint256 staleWindow = liquifierInstance.STALE_PRICE_WINDOW();
        // updatedAt + window < now → stale → check skipped even with absurd answer.
        _mockChainlinkAnswer(int256(100 ether), block.timestamp - staleWindow - 1);

        uint256 q = liquifierInstance.quoteByMarketValue(address(stEth), 1 ether);
        assertGt(q, 0);
        assertLe(q, 1 ether);
    }

    // -----------------------------------------------------------------------
    // End-to-end: deposit reverts when the feed disagrees
    // -----------------------------------------------------------------------

    /// Full deposit flow must surface the price-feed revert; the inbound stETH
    /// transfer is rolled back atomically.
    function test_depositWithERC20_revertsOnMockedAbovePremium() public {
        _seedStEth(alice, 2 ether);

        _mockChainlinkAnswer(int256(1.5 ether), block.timestamp);

        vm.startPrank(alice);
        stEth.approve(address(liquifierInstance), 1 ether);
        vm.expectRevert(Liquifier.InvalidStEthPrice.selector);
        liquifierInstance.depositWithERC20(address(stEth), 1 ether, address(0));
        vm.stopPrank();
    }

    /// Same flow with a stale mocked feed succeeds (check skipped).
    function test_depositWithERC20_passesOnMockedStaleFeed() public {
        _seedStEth(alice, 2 ether);

        uint256 staleWindow = liquifierInstance.STALE_PRICE_WINDOW();
        _mockChainlinkAnswer(int256(100 ether), block.timestamp - staleWindow - 1);

        uint256 eEthBefore = eETHInstance.balanceOf(alice);

        vm.startPrank(alice);
        stEth.approve(address(liquifierInstance), 1 ether);
        liquifierInstance.depositWithERC20(address(stEth), 1 ether, address(0));
        vm.stopPrank();

        assertGt(eETHInstance.balanceOf(alice), eEthBefore, "deposit should mint eETH");
    }

    // -----------------------------------------------------------------------
    // Fuzz: assert the contract's predicate matches a plain re-implementation
    // when run against the LIVE curve pool quote at the fork block.
    // -----------------------------------------------------------------------

    function testFuzz_priceFeedPredicateMatchesContract_onFork(
        int256 answer,
        uint256 age
    ) public {
        answer = bound(answer, 1, int256(uint256(2 ether))); // 0..2 ETH per stETH
        uint256 staleWindow = liquifierInstance.STALE_PRICE_WINDOW();
        age = bound(age, 0, staleWindow * 2);

        uint256 amount = 1 ether;
        uint256 updatedAt = block.timestamp - age;
        _mockChainlinkAnswer(answer, updatedAt);

        // Live curve out for the fork block.
        uint256 curveOut =
            ICurvePoolQuoter1(address(liquifierInstance.stEth_Eth_Pool())).get_dy(1, 0, amount);

        uint256 marketValue = curveOut < amount ? curveOut : amount;
        uint256 chainlinkValue = (uint256(answer) * amount) / 1e18;
        bool fresh = updatedAt + staleWindow >= block.timestamp;

        if (fresh && chainlinkValue > marketValue + liquifierInstance.MAX_OFF_CHAIN_PREMIUM()) {
            vm.expectRevert(Liquifier.InvalidStEthPrice.selector);
            liquifierInstance.quoteByMarketValue(address(stEth), amount);
        } else {
            uint256 q = liquifierInstance.quoteByMarketValue(address(stEth), amount);
            assertEq(q, marketValue);
        }
    }

    // -----------------------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------------------

    function _mockChainlinkAnswer(int256 answer, uint256 updatedAt) internal {
        vm.mockCall(
            CHAINLINK_STETH_ETH_FEED,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(uint80(0), answer, uint256(0), updatedAt, uint80(0))
        );
    }

    function _seedStEth(address to, uint256 amount) internal {
        vm.deal(to, amount + 1 ether);
        vm.prank(to);
        stEth.submit{value: amount}(address(0));
    }
}
