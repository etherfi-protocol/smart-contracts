// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "forge-std/Script.sol";
import "forge-std/console2.sol";
import {Deployed} from "../../deploys/Deployed.s.sol";
import {EtherFiRestaker} from "../../../src/EtherFiRestaker.sol";
import {ILidoWithdrawalQueue} from "../../../src/interfaces/ILiquifier.sol";

// forge script script/operations/steth-claim-withdrawals/ClaimStEthWithdrawals.s.sol --fork-url $MAINNET_RPC_URL -vvvv

contract ClaimStEthWithdrawals is Script, Deployed {

    EtherFiRestaker constant etherFiRestaker = EtherFiRestaker(payable(ETHERFI_RESTAKER));

    function run() external {
        uint256 startId = 113785; // Set this to the first request you want to claim
        uint256 endId = 113863; // Set this to the last request you want to claim

        ILidoWithdrawalQueue lidoWithdrawalQueue = etherFiRestaker.lidoWithdrawalQueue();
        console2.log("LidoWithdrawalQueue:", address(lidoWithdrawalQueue));

        // Cap endId to the last finalized request
        uint256 lastFinalizedId = lidoWithdrawalQueue.getLastFinalizedRequestId();
        console2.log("Last finalized request ID:", lastFinalizedId);

        if (endId > lastFinalizedId) {
            console2.log("WARNING: endId", endId, "exceeds last finalized ID, capping to", lastFinalizedId);
            endId = lastFinalizedId;
        }
        require(startId <= endId, "No finalized requests in range");

        uint256 count = endId - startId + 1;
        console2.log("Claiming", count, "requests:", startId);
        console2.log("  to", endId);

        uint256[] memory requestIds = new uint256[](count);
        for (uint256 i = 0; i < count; i++) {
            requestIds[i] = startId + i;
        }

        // Get checkpoint hints
        uint256 lastCheckpointIndex = lidoWithdrawalQueue.getLastCheckpointIndex();
        console2.log("Last checkpoint index:", lastCheckpointIndex);

        uint256[] memory hints = lidoWithdrawalQueue.findCheckpointHints(requestIds, 1, lastCheckpointIndex);

        console2.log("Hints found for", hints.length, "requests");
        for (uint256 i = 0; i < hints.length; i++) {
            console2.log("  requestId:", requestIds[i], "hint:", hints[i]);
        }

        // Encode the calldata
        bytes memory callData = abi.encodeWithSelector(
            EtherFiRestaker.stEthClaimWithdrawals.selector,
            requestIds,
            hints
        );

        console2.log("");
        console2.log("=== stEthClaimWithdrawals calldata ===");
        console2.log("Target:", address(etherFiRestaker));
        console2.logBytes(callData);

        // Simulate the transaction on fork as operating admin
        console2.log("");
        console2.log("=== Simulating on fork ===");
        uint256 liquidityPoolbalanceBefore = LIQUIDITY_POOL.balance;
        console2.log("LiquidityPool balance before:", uint256(liquidityPoolbalanceBefore) / 1e18);
        vm.prank(ETHERFI_OPERATING_ADMIN);
        etherFiRestaker.stEthClaimWithdrawals(requestIds, hints);
        uint256 liquidityPoolbalanceAfter = LIQUIDITY_POOL.balance;
        console2.log("LiquidityPool balance after:", uint256(liquidityPoolbalanceAfter) / 1e18);
        console2.log("ETH claimed:", (liquidityPoolbalanceAfter - liquidityPoolbalanceBefore) / 1e18);
        console2.log("Simulation successful");
    }
}
