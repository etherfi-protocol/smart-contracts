// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "forge-std/Script.sol";
import "forge-std/console2.sol";
import {Deployed} from "../../deploys/Deployed.s.sol";
import {EtherFiRestaker} from "../../../src/EtherFiRestaker.sol";
import {ILidoWithdrawalQueue} from "../../../src/interfaces/ILiquifier.sol";

// forge script script/operations/steth-management/ClaimStEthWithdrawals.s.sol --fork-url $MAINNET_RPC_URL -vvvv

contract ClaimStEthWithdrawals is Script, Deployed {

    EtherFiRestaker constant etherFiRestaker = EtherFiRestaker(payable(ETHERFI_RESTAKER));

    function run() external {
        ILidoWithdrawalQueue lidoWithdrawalQueue = ILidoWithdrawalQueue(address(etherFiRestaker.lidoWithdrawalQueue()));
        console2.log("EtherFiRestaker:     ", address(etherFiRestaker));
        console2.log("LidoWithdrawalQueue: ", address(lidoWithdrawalQueue));

        // 1. Fetch all withdrawal request IDs owned by the restaker
        uint256[] memory allRequestIds = lidoWithdrawalQueue.getWithdrawalRequests(address(etherFiRestaker));
        console2.log("Total pending requests for restaker:", allRequestIds.length);

        if (allRequestIds.length == 0) {
            console2.log("No pending withdrawal requests found. Nothing to claim.");
            return;
        }

        // 2. Get statuses for all requests
        ILidoWithdrawalQueue.WithdrawalRequestStatus[] memory statuses =
            lidoWithdrawalQueue.getWithdrawalStatus(allRequestIds);

        // 3. Filter to finalized & unclaimed requests
        uint256 claimableCount = 0;
        for (uint256 i = 0; i < statuses.length; i++) {
            if (statuses[i].isFinalized && !statuses[i].isClaimed) {
                claimableCount++;
            }
        }

        console2.log("Claimable (finalized & unclaimed):", claimableCount);

        if (claimableCount == 0) {
            console2.log("No claimable requests at this time. Nothing to claim.");
            return;
        }

        uint256[] memory requestIds = new uint256[](claimableCount);
        uint256 idx = 0;
        for (uint256 i = 0; i < allRequestIds.length; i++) {
            if (statuses[i].isFinalized && !statuses[i].isClaimed) {
                requestIds[idx] = allRequestIds[i];
                idx++;
            }
        }

        _sortAscending(requestIds);

        console2.log("Claiming request IDs:");
        for (uint256 i = 0; i < requestIds.length; i++) {
            console2.log(" ", requestIds[i]);
        }

        // 4. Get checkpoint hints for the claimable requests
        uint256 lastCheckpointIndex = lidoWithdrawalQueue.getLastCheckpointIndex();
        console2.log("Last checkpoint index:", lastCheckpointIndex);

        uint256[] memory hints = lidoWithdrawalQueue.findCheckpointHints(requestIds, 1, lastCheckpointIndex);

        console2.log("Hints found for", hints.length, "requests:");
        for (uint256 i = 0; i < hints.length; i++) {
            console2.log("  requestId:", requestIds[i], "hint:", hints[i]);
        }

        // 5. Encode calldata for multisig / safe submission
        bytes memory callData = abi.encodeWithSelector(
            EtherFiRestaker.stEthClaimWithdrawals.selector,
            requestIds,
            hints
        );

        console2.log("");
        console2.log("=== stEthClaimWithdrawals calldata ===");
        console2.log("Target:", address(etherFiRestaker));
        console2.logBytes(callData);

        // 6. Simulate on fork as operating admin
        console2.log("");
        console2.log("=== Simulating on fork ===");
        uint256 lpBalanceBefore = LIQUIDITY_POOL.balance;
        console2.log("LiquidityPool balance before:", lpBalanceBefore / 1e18);
        vm.prank(ETHERFI_OPERATING_ADMIN);
        etherFiRestaker.stEthClaimWithdrawals(requestIds, hints);
        uint256 lpBalanceAfter = LIQUIDITY_POOL.balance;
        console2.log("LiquidityPool balance after:", lpBalanceAfter / 1e18);
        console2.log("ETH claimed:", (lpBalanceAfter - lpBalanceBefore) / 1e18);
        console2.log("Simulation successful");
    }

    function _sortAscending(uint256[] memory arr) internal pure {
        uint256 length = arr.length;
        for (uint256 i = 1; i < length; i++) {
            uint256 key = arr[i];
            uint256 j = i;
            while (j > 0 && arr[j - 1] > key) {
                arr[j] = arr[j - 1];
                j--;
            }
            arr[j] = key;
        }
    }
}
