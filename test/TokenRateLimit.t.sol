// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "./TestSetup.sol";
import "../src/interfaces/IEtherFiRateLimiter.sol";

contract TokenRateLimitTest is TestSetup {
    uint64 private constant ONE_ETHER_GWEI = 1 ether / 1 gwei; // 1e9

    function setUp() public {
        setUpTests();

        // Fund alice + bob with eETH so transfer/burn/wrap tests have balance to move.
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
        vm.prank(alice);
        liquidityPoolInstance.deposit{value: 50 ether}();
        vm.prank(bob);
        liquidityPoolInstance.deposit{value: 50 ether}();
    }

    function _setCapacityAndRefill(bytes32 id, uint64 capacity, uint64 refill) internal {
        vm.startPrank(admin);
        rateLimiterInstance.setCapacity(id, capacity);
        rateLimiterInstance.setRefillRate(id, refill);
        rateLimiterInstance.setRemaining(id, capacity);
        vm.stopPrank();
    }

    // ---------- eETH ----------

    function test_eETH_mint_consumes_bucket() public {
        bytes32 id = eETHInstance.EETH_MINT_LIMIT_ID();
        _setCapacityAndRefill(id, uint64(2 ether / 1 gwei), 0);

        // Below capacity: succeeds.
        vm.deal(chad, 5 ether);
        vm.prank(chad);
        liquidityPoolInstance.deposit{value: 1 ether}();

        // Next 1.5 ether mint exceeds the remaining 1 ether of capacity → revert.
        vm.prank(chad);
        vm.expectRevert(IEtherFiRateLimiter.LimitExceeded.selector);
        liquidityPoolInstance.deposit{value: 1.5 ether}();
    }

    function test_eETH_burn_consumes_bucket() public {
        bytes32 id = eETHInstance.EETH_BURN_LIMIT_ID();
        // burnShares mutates totalShares before computing amountForShare, so each 1-ether
        // share consumes slightly more than 1 ETH (the pool ether stays put in this test
        // harness while shares shrink). 2 ETH capacity fits the first burn but not two.
        _setCapacityAndRefill(id, uint64(2 ether / 1 gwei), 0);

        uint256 oneEthShare = liquidityPoolInstance.sharesForAmount(1 ether);
        vm.prank(address(liquidityPoolInstance));
        eETHInstance.burnShares(alice, oneEthShare);

        vm.prank(address(liquidityPoolInstance));
        vm.expectRevert(IEtherFiRateLimiter.LimitExceeded.selector);
        eETHInstance.burnShares(alice, oneEthShare);
    }

    function test_eETH_transfer_consumes_bucket() public {
        bytes32 id = eETHInstance.EETH_TRANSFER_LIMIT_ID();
        _setCapacityAndRefill(id, uint64(1 ether / 1 gwei), 0);

        vm.prank(alice);
        eETHInstance.transfer(bob, 1 ether);

        vm.prank(alice);
        vm.expectRevert(IEtherFiRateLimiter.LimitExceeded.selector);
        eETHInstance.transfer(bob, 1 ether);
    }

    function test_eETH_bucket_refills_over_time() public {
        bytes32 id = eETHInstance.EETH_TRANSFER_LIMIT_ID();
        _setCapacityAndRefill(id, uint64(1 ether / 1 gwei), uint64(0.1 ether / 1 gwei));

        vm.prank(alice);
        eETHInstance.transfer(bob, 1 ether);

        vm.prank(alice);
        vm.expectRevert(IEtherFiRateLimiter.LimitExceeded.selector);
        eETHInstance.transfer(bob, 0.1 ether);

        // 1 second of refill at 0.1 ETH/sec returns ~0.1 ETH of capacity.
        vm.warp(block.timestamp + 1);
        vm.prank(alice);
        eETHInstance.transfer(bob, 0.1 ether);
    }

    function test_eETH_admin_setRemaining_unblocks() public {
        bytes32 id = eETHInstance.EETH_TRANSFER_LIMIT_ID();
        _setCapacityAndRefill(id, uint64(1 ether / 1 gwei), 0);

        vm.prank(alice);
        eETHInstance.transfer(bob, 1 ether);

        // Top up bucket via emergency admin path.
        vm.prank(admin);
        rateLimiterInstance.setRemaining(id, uint64(1 ether / 1 gwei));

        vm.prank(alice);
        eETHInstance.transfer(bob, 1 ether);
    }

    // ---------- weETH ----------

    function test_weETH_wrap_consumes_mint_bucket() public {
        bytes32 mintId = weEthInstance.WEETH_MINT_LIMIT_ID();
        _setCapacityAndRefill(mintId, uint64(1 ether / 1 gwei), 0);

        vm.startPrank(alice);
        eETHInstance.approve(address(weEthInstance), type(uint256).max);
        weEthInstance.wrap(1 ether);

        vm.expectRevert(IEtherFiRateLimiter.LimitExceeded.selector);
        weEthInstance.wrap(1 ether);
        vm.stopPrank();
    }

    function test_weETH_wrap_also_consumes_eETH_transfer_bucket() public {
        // Wrap routes eETH from user → weETH via transferFrom, so the eETH transfer
        // bucket must allow the underlying eETH movement even when WEETH_MINT is open.
        bytes32 weEthMintId = weEthInstance.WEETH_MINT_LIMIT_ID();
        bytes32 eEthTransferId = eETHInstance.EETH_TRANSFER_LIMIT_ID();
        _setCapacityAndRefill(weEthMintId, type(uint64).max, 0);
        _setCapacityAndRefill(eEthTransferId, uint64(1 ether / 1 gwei), 0);

        vm.startPrank(alice);
        eETHInstance.approve(address(weEthInstance), type(uint256).max);
        weEthInstance.wrap(1 ether);

        // eETH transfer bucket is now depleted → second wrap reverts on the eETH side.
        vm.expectRevert(IEtherFiRateLimiter.LimitExceeded.selector);
        weEthInstance.wrap(1 ether);
        vm.stopPrank();
    }

    function test_weETH_unwrap_consumes_burn_bucket() public {
        bytes32 burnId = weEthInstance.WEETH_BURN_LIMIT_ID();
        // Wrap first under unconstrained limits.
        vm.startPrank(alice);
        eETHInstance.approve(address(weEthInstance), type(uint256).max);
        uint256 weAmount = weEthInstance.wrap(2 ether);
        vm.stopPrank();

        _setCapacityAndRefill(burnId, uint64(weAmount / 1 gwei), 0);

        vm.startPrank(alice);
        weEthInstance.unwrap(weAmount);

        vm.expectRevert(IEtherFiRateLimiter.LimitExceeded.selector);
        weEthInstance.unwrap(1);
        vm.stopPrank();
    }

    function test_weETH_transfer_consumes_bucket() public {
        // Get alice some weETH balance.
        vm.startPrank(alice);
        eETHInstance.approve(address(weEthInstance), type(uint256).max);
        uint256 weAmount = weEthInstance.wrap(2 ether);
        vm.stopPrank();

        bytes32 id = weEthInstance.WEETH_TRANSFER_LIMIT_ID();
        _setCapacityAndRefill(id, uint64(weAmount / 1 gwei), 0);

        vm.prank(alice);
        weEthInstance.transfer(bob, weAmount);

        vm.prank(bob);
        vm.expectRevert(IEtherFiRateLimiter.LimitExceeded.selector);
        weEthInstance.transfer(alice, 1);
    }

    function test_weETH_mint_burn_do_not_consume_transfer_bucket() public {
        // Set TRANSFER capacity to zero. wrap (mint) and unwrap (burn) must still
        // work because the _beforeTokenTransfer hook only consumes the transfer
        // bucket for user→user moves.
        bytes32 transferId = weEthInstance.WEETH_TRANSFER_LIMIT_ID();
        _setCapacityAndRefill(transferId, 0, 0);

        vm.startPrank(alice);
        eETHInstance.approve(address(weEthInstance), type(uint256).max);
        uint256 weAmount = weEthInstance.wrap(1 ether);
        weEthInstance.unwrap(weAmount);
        vm.stopPrank();
    }

    // ---------- capacity == 0 disabled-mode (skip checks) ----------

    function test_eETH_transfer_skips_when_capacity_zero() public {
        bytes32 id = eETHInstance.EETH_TRANSFER_LIMIT_ID();
        _setCapacityAndRefill(id, 0, 0);

        // Multiple transfers of any size succeed because the limit is in disabled mode.
        vm.startPrank(alice);
        for (uint256 i = 0; i < 5; i++) {
            eETHInstance.transfer(bob, 1 ether);
        }
        vm.stopPrank();
    }

    function test_eETH_mint_burn_skip_when_capacity_zero() public {
        _setCapacityAndRefill(eETHInstance.EETH_MINT_LIMIT_ID(), 0, 0);
        _setCapacityAndRefill(eETHInstance.EETH_BURN_LIMIT_ID(), 0, 0);

        vm.deal(chad, 100 ether);
        vm.prank(chad);
        liquidityPoolInstance.deposit{value: 10 ether}();

        uint256 oneEthShare = liquidityPoolInstance.sharesForAmount(1 ether);
        vm.prank(address(liquidityPoolInstance));
        eETHInstance.burnShares(chad, oneEthShare);
    }

    function test_weETH_all_buckets_skip_when_capacity_zero() public {
        _setCapacityAndRefill(weEthInstance.WEETH_MINT_LIMIT_ID(), 0, 0);
        _setCapacityAndRefill(weEthInstance.WEETH_BURN_LIMIT_ID(), 0, 0);
        _setCapacityAndRefill(weEthInstance.WEETH_TRANSFER_LIMIT_ID(), 0, 0);
        _setCapacityAndRefill(eETHInstance.EETH_TRANSFER_LIMIT_ID(), 0, 0);

        vm.startPrank(alice);
        eETHInstance.approve(address(weEthInstance), type(uint256).max);
        uint256 weAmount = weEthInstance.wrap(5 ether);
        weEthInstance.transfer(bob, weAmount / 2);
        weEthInstance.unwrap(weAmount / 4);
        vm.stopPrank();
    }

    function test_disabled_bucket_still_requires_existence() public {
        // Sanity: getLimit reverts when the bucket was never created, so token code
        // can't accidentally bypass rate limits by deploying without bootstrap.
        bytes32 unknownId = keccak256("DOES_NOT_EXIST");
        vm.expectRevert(IEtherFiRateLimiter.UnknownLimit.selector);
        rateLimiterInstance.getLimit(unknownId);
    }

    function test_capacity_restoration_re_enables_throttling() public {
        bytes32 id = eETHInstance.EETH_TRANSFER_LIMIT_ID();

        // Start disabled — unlimited transfers work.
        _setCapacityAndRefill(id, 0, 0);
        vm.prank(alice);
        eETHInstance.transfer(bob, 10 ether);

        // Re-enable with a small cap — next transfer above cap reverts.
        _setCapacityAndRefill(id, uint64(1 ether / 1 gwei), 0);
        vm.prank(alice);
        eETHInstance.transfer(bob, 1 ether);
        vm.prank(alice);
        vm.expectRevert(IEtherFiRateLimiter.LimitExceeded.selector);
        eETHInstance.transfer(bob, 1 ether);
    }
}
