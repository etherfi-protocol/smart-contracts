// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "./TestSetup.sol";

contract WhaleWeETHToStETHRedemptionTest is TestSetup {

    address constant WHALE = 0x7ee29373F075eE1d83b1b93b4fe94ae242Df5178;
    address constant STETH = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;
    uint256 constant REDEMPTION_AMOUNT_WEETH = 280_000 ether;

    function setUp() public {
        initializeRealisticFork(MAINNET_FORK);
    }

    function _logRedemptionConfig(string memory label) internal view {
        (
            ,
            uint16 exitFeeSplitToTreasuryInBps,
            uint16 exitFeeInBps,
            uint16 lowWatermarkInBpsOfTvl
        ) = etherFiRedemptionManagerInstance.tokenToRedemptionInfo(STETH);

        console.log(label);
        console.log("  exitFeeInBps:              ", exitFeeInBps);
        console.log("  exitFeeSplitToTreasuryBps: ", exitFeeSplitToTreasuryInBps);
        console.log("  lowWatermarkInBpsOfTvl:    ", lowWatermarkInBpsOfTvl);
        console.log("  lowWatermarkInETH:         ", etherFiRedemptionManagerInstance.lowWatermarkInETH(STETH) / 1e18, "ETH");
        console.log("  totalRedeemable:           ", etherFiRedemptionManagerInstance.totalRedeemableAmount(STETH) / 1e18, "stETH");
        console.log("  instantLiquidity:          ", etherFiRedemptionManagerInstance.getInstantLiquidityAmount(STETH) / 1e18, "stETH");
    }

    function _configureRedemptionManager(uint256 eEthEquivalent) internal {
        address redemptionManagerAdmin = etherFiRedemptionManagerInstance.roleRegistry().owner();

        vm.startPrank(redemptionManagerAdmin);
        roleRegistryInstance.grantRole(
            etherFiRedemptionManagerInstance.ETHERFI_REDEMPTION_MANAGER_ADMIN_ROLE(),
            redemptionManagerAdmin
        );

        // Set exit fee to 0 for this whale redemption
        etherFiRedemptionManagerInstance.setExitFeeBasisPoints(0, STETH);

        // Remove low watermark so full stETH balance is available
        etherFiRedemptionManagerInstance.setLowWatermarkInBpsOfTvl(0, STETH);

        // Increase rate limiter capacity to allow the full redemption
        etherFiRedemptionManagerInstance.setCapacity(eEthEquivalent + 5000 ether, STETH);
        etherFiRedemptionManagerInstance.setRefillRatePerSecond(eEthEquivalent + 5000 ether, STETH);
        vm.stopPrank();

        vm.warp(block.timestamp + 1);
    }

    function _mintWeEthToWhale(uint256 weEthNeeded) internal {
        uint256 eEthNeeded = weEthInstance.getEETHByWeETH(weEthNeeded) + 1 ether;
        vm.deal(WHALE, eEthNeeded);

        vm.startPrank(WHALE);
        liquidityPoolInstance.deposit{value: eEthNeeded}(address(0));
        eETHInstance.approve(address(weEthInstance), type(uint256).max);
        weEthInstance.wrap(eETHInstance.balanceOf(WHALE));
        vm.stopPrank();

        require(weEthInstance.balanceOf(WHALE) >= weEthNeeded, "Failed to mint enough weETH");
    }

    function _ensureRestakerStEth(uint256 stEthNeeded) internal {
        uint256 currentBalance = stEth.balanceOf(address(etherFiRestakerInstance));
        if (currentBalance >= stEthNeeded) return;

        uint256 deficit = stEthNeeded - currentBalance + 2 ether;
        uint256 chunkSize = 149_000 ether;
        address depositor = address(0xDEAD);

        vm.startPrank(owner);
        liquifierInstance.updateDepositCap(STETH, 500_000, 4_000_000);
        vm.stopPrank();

        uint32 refreshInterval = liquifierInstance.timeBoundCapRefreshInterval();
        vm.warp(block.timestamp + refreshInterval + 1);
        vm.roll(block.number + 7200);

        while (deficit > 0) {
            uint256 amount = deficit > chunkSize ? chunkSize : deficit;
            vm.deal(depositor, amount);

            vm.startPrank(depositor);
            stEth.submit{value: amount}(address(0));
            stEth.approve(address(liquifierInstance), amount);
            liquifierInstance.depositWithERC20(STETH, amount, address(0));
            vm.stopPrank();

            deficit = deficit > amount ? deficit - amount : 0;

            if (deficit > 0) {
                vm.warp(block.timestamp + refreshInterval + 1);
                vm.roll(block.number + 7200);
            }
        }

        require(
            stEth.balanceOf(address(etherFiRestakerInstance)) >= stEthNeeded,
            "Failed to fund restaker stETH"
        );
    }

    function test_whale_canRedeem_check() public view {
        uint256 whaleWeEthBalance = weEthInstance.balanceOf(WHALE);
        uint256 eEthEquivalent = weEthInstance.getEETHByWeETH(REDEMPTION_AMOUNT_WEETH);
        uint256 restakerStEth = stEth.balanceOf(address(etherFiRestakerInstance));

        console.log("=== Whale Redemption Feasibility Check ===");
        console.log("Whale weETH balance:       ", whaleWeEthBalance / 1e18, "weETH");
        console.log("Requested weETH:           ", REDEMPTION_AMOUNT_WEETH / 1e18, "weETH");
        console.log("eETH equivalent:           ", eEthEquivalent / 1e18, "eETH");
        console.log("Restaker stETH balance:    ", restakerStEth / 1e18, "stETH");
        console.log("");

        _logRedemptionConfig("--- Current Config (stETH) ---");

        console.log("");
        console.log("--- Checks ---");
        console.log("Whale has enough weETH:    ", whaleWeEthBalance >= REDEMPTION_AMOUNT_WEETH);
        console.log("Restaker has enough stETH: ", restakerStEth >= eEthEquivalent);

        if (restakerStEth < eEthEquivalent) {
            console.log("SHORTFALL:                 ", (eEthEquivalent - restakerStEth) / 1e18, "stETH");
        }
    }

    function test_whale_redeemWeEth_toStETH() public {
        uint256 estimatedEEth = weEthInstance.getEETHByWeETH(REDEMPTION_AMOUNT_WEETH);

        // --- Log current config BEFORE any changes ---
        _logRedemptionConfig("=== Current Config (stETH) ===");
        console.log("");

        // --- Setup: fund restaker and whale ---
        _ensureRestakerStEth(estimatedEEth + 10 ether);
        _mintWeEthToWhale(REDEMPTION_AMOUNT_WEETH);

        uint256 eEthEquivalent = weEthInstance.getEETHByWeETH(REDEMPTION_AMOUNT_WEETH);
        uint256 whaleWeEthBalance = weEthInstance.balanceOf(WHALE);
        uint256 whaleStEthBefore = stEth.balanceOf(WHALE);
        uint256 restakerStEthBefore = stEth.balanceOf(address(etherFiRestakerInstance));

        console.log("=== Pre-Redemption State ===");
        console.log("Whale weETH:               ", whaleWeEthBalance / 1e18, "weETH");
        console.log("Restaker stETH:            ", restakerStEthBefore / 1e18, "stETH");
        console.log("eETH equivalent:           ", eEthEquivalent / 1e18, "eETH");
        console.log("");

        // --- Admin: configure redemption manager (fee=0, watermark=0, capacity=max) ---
        _configureRedemptionManager(eEthEquivalent);

        // --- Log config AFTER admin changes ---
        _logRedemptionConfig("=== Post-Config (stETH) ===");
        console.log("");

        require(
            etherFiRedemptionManagerInstance.canRedeem(eEthEquivalent, STETH),
            "Cannot redeem after admin config"
        );

        // --- Preview (should be zero fee) ---
        uint256 eEthShares = liquidityPoolInstance.sharesForAmount(eEthEquivalent);
        uint256 stEthToReceive = etherFiRedemptionManagerInstance.previewRedeem(eEthShares, STETH);
        console.log("=== Redemption Preview ===");
        console.log("eETH shares:               ", eEthShares / 1e18);
        console.log("stETH to receive:          ", stEthToReceive / 1e18, "stETH");
        console.log("Exit fee:                  ", (eEthEquivalent - stEthToReceive) / 1e18, "stETH");
        console.log("");

        // With fee=0, whale should receive the full eETH equivalent in stETH
        assertApproxEqAbs(stEthToReceive, eEthEquivalent, 1 ether);

        // --- Execute redemption ---
        vm.startPrank(WHALE);
        weEthInstance.approve(address(etherFiRedemptionManagerInstance), REDEMPTION_AMOUNT_WEETH);
        etherFiRedemptionManagerInstance.redeemWeEth(REDEMPTION_AMOUNT_WEETH, WHALE, STETH);
        vm.stopPrank();

        // --- Verify ---
        uint256 whaleStEthAfter = stEth.balanceOf(WHALE);
        uint256 restakerStEthAfter = stEth.balanceOf(address(etherFiRestakerInstance));

        console.log("=== Post-Redemption ===");
        console.log("Whale weETH remaining:     ", weEthInstance.balanceOf(WHALE) / 1e18, "weETH");
        console.log("Whale stETH received:      ", (whaleStEthAfter - whaleStEthBefore) / 1e18, "stETH");
        console.log("Restaker stETH remaining:  ", restakerStEthAfter / 1e18, "stETH");

        // Whale burned all 280k weETH
        assertEq(weEthInstance.balanceOf(WHALE), whaleWeEthBalance - REDEMPTION_AMOUNT_WEETH);

        // Whale received stETH (zero fee -> full eETH equivalent)
        assertApproxEqAbs(whaleStEthAfter - whaleStEthBefore, stEthToReceive, 2);

        // Restaker stETH decreased accordingly
        assertApproxEqAbs(restakerStEthBefore - restakerStEthAfter, stEthToReceive, 2);
    }
}
