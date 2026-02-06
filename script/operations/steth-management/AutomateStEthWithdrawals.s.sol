// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "forge-std/Script.sol";
import "forge-std/console2.sol";
import {Deployed} from "../../deploys/Deployed.s.sol";
import {EtherFiRestaker} from "../../../src/EtherFiRestaker.sol";
import {ILido, ILidoWithdrawalQueue} from "../../../src/interfaces/ILiquifier.sol";

// Full withdrawal:
//   FULL_WITHDRAWAL=true forge script script/operations/steth-claim-withdrawals/AutomateStEthWithdrawals.s.sol --fork-url $MAINNET_RPC_URL -vvvv
//
// Partial withdrawal (amount in ether):
//   AMOUNT=100 forge script script/operations/steth-claim-withdrawals/AutomateStEthWithdrawals.s.sol --fork-url $MAINNET_RPC_URL -vvvv

contract AutomateStEthWithdrawals is Script, Deployed {

    EtherFiRestaker constant etherFiRestaker = EtherFiRestaker(payable(ETHERFI_RESTAKER));

    function run() external {
        ILidoWithdrawalQueue lidoWithdrawalQueue = etherFiRestaker.lidoWithdrawalQueue();
        ILido lido = etherFiRestaker.lido();

        bool fullWithdrawal = vm.envOr("FULL_WITHDRAWAL", false);
        uint256 amountInEther = vm.envOr("AMOUNT", uint256(0));
        require(fullWithdrawal || amountInEther > 0, "Set FULL_WITHDRAWAL=true or AMOUNT=<ether>");

        uint256 stEthBalance = lido.balanceOf(address(etherFiRestaker));
        uint256 amount = fullWithdrawal ? stEthBalance : amountInEther * 1 ether;

        console2.log("EtherFiRestaker stETH balance:", stEthBalance);
        console2.log("Withdrawal amount:", amount);
        console2.log("Mode:", fullWithdrawal ? "full" : "partial");
        console2.log("");

        // ========================================================
        // Step 1: Request stETH Withdrawal
        // ========================================================
        console2.log("=== Step 1: Request stETH Withdrawal ===");

        vm.startPrank(ETHERFI_OPERATING_ADMIN);
        uint256[] memory reqIds;
        if (fullWithdrawal) {
            reqIds = etherFiRestaker.stEthRequestWithdrawal();
        } else {
            reqIds = etherFiRestaker.stEthRequestWithdrawal(amount);
        }
        vm.stopPrank();

        console2.log("Created", reqIds.length, "withdrawal requests:");
        for (uint256 i = 0; i < reqIds.length; i++) {
            console2.log("  requestId:", reqIds[i]);
        }

        // Log request calldata
        bytes memory requestCalldata;
        if (fullWithdrawal) {
            requestCalldata = abi.encodeWithSignature("stEthRequestWithdrawal()");
        } else {
            requestCalldata = abi.encodeWithSignature("stEthRequestWithdrawal(uint256)", amount);
        }

        console2.log("");
        console2.log("=== stEthRequestWithdrawal calldata ===");
        console2.log("Target:", address(etherFiRestaker));
        console2.logBytes(requestCalldata);

        // ========================================================
        // Step 2: Simulate Lido Finalization on Fork
        // ========================================================
        console2.log("");
        console2.log("=== Step 2: Simulate Lido Finalization ===");

        uint256 lastReqId = reqIds[reqIds.length - 1];
        _simulateLidoFinalization(lidoWithdrawalQueue, lido, lastReqId);

        // ========================================================
        // Step 3: Claim Finalized Withdrawals
        // ========================================================
        console2.log("");
        console2.log("=== Step 3: Claim Finalized Withdrawals ===");

        uint256 lastFinalizedId = lidoWithdrawalQueue.getLastFinalizedRequestId();
        console2.log("Last finalized request ID:", lastFinalizedId);

        // Filter to only finalized requests
        uint256 claimableCount = 0;
        for (uint256 i = 0; i < reqIds.length; i++) {
            if (reqIds[i] <= lastFinalizedId) claimableCount++;
        }
        require(claimableCount > 0, "No requests finalized yet");
        console2.log("Claimable:", claimableCount, "of", reqIds.length);

        uint256[] memory claimableIds = new uint256[](claimableCount);
        uint256 idx = 0;
        for (uint256 i = 0; i < reqIds.length; i++) {
            if (reqIds[i] <= lastFinalizedId) {
                claimableIds[idx++] = reqIds[i];
            }
        }

        // Get checkpoint hints
        uint256 lastCheckpointIndex = lidoWithdrawalQueue.getLastCheckpointIndex();
        uint256[] memory hints = lidoWithdrawalQueue.findCheckpointHints(claimableIds, 1, lastCheckpointIndex);

        // Log claim calldata
        bytes memory claimCalldata = abi.encodeWithSelector(
            EtherFiRestaker.stEthClaimWithdrawals.selector,
            claimableIds,
            hints
        );

        console2.log("");
        console2.log("=== stEthClaimWithdrawals calldata ===");
        console2.log("Target:", address(etherFiRestaker));
        console2.logBytes(claimCalldata);

        // Simulate the claim
        console2.log("");
        console2.log("=== Simulating claim on fork ===");
        uint256 lpEthBefore = LIQUIDITY_POOL.balance;

        vm.prank(ETHERFI_OPERATING_ADMIN);
        etherFiRestaker.stEthClaimWithdrawals(claimableIds, hints);

        uint256 lpEthAfter = LIQUIDITY_POOL.balance;
        console2.log("ETH sent to Liquidity Pool:", lpEthAfter - lpEthBefore);
        console2.log("Simulation successful");
    }

    function _simulateLidoFinalization(
        ILidoWithdrawalQueue _queue,
        ILido _lido,
        uint256 _lastRequestId
    ) internal {
        // Compute the current stETH share rate in ray (1e27)
        uint256 totalPooledEther = _lido.getTotalPooledEther();
        uint256 totalShares = _lido.getTotalShares();
        uint256 shareRate = (totalPooledEther * 1e27) / totalShares;
        console2.log("Current stETH share rate (ray):", shareRate);

        // Calculate ETH needed to finalize
        uint256[] memory batches = new uint256[](1);
        batches[0] = _lastRequestId;
        (uint256 ethToLock,) = _queue.prefinalize(batches, shareRate);
        console2.log("ETH needed for finalization:", ethToLock);

        // Prank as the Lido finalizer role holder
        bytes32 finalizeRole = _queue.FINALIZE_ROLE();
        address finalizer = _queue.getRoleMember(finalizeRole, 0);
        console2.log("Lido finalizer:", finalizer);

        vm.deal(finalizer, finalizer.balance + ethToLock);
        vm.prank(finalizer);
        _queue.finalize{value: ethToLock}(_lastRequestId, shareRate);

        console2.log("Finalization simulated up to request ID:", _lastRequestId);
    }
}
