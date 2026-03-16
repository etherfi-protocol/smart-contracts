// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "forge-std/Script.sol";
import "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Deployed} from "../../deploys/Deployed.s.sol";
import {EtherFiRestaker} from "../../../src/EtherFiRestaker.sol";
import {IDelegationManager} from "../../../src/eigenlayer-interfaces/IDelegationManager.sol";

// Complete all pending EigenLayer stETH withdrawal queues on the restaker:
//   forge script script/operations/steth-management/CompleteQueuedWithdrawalsStETH.s.sol --fork-url $MAINNET_RPC_URL -vvvv

contract CompleteQueuedWithdrawalsStETH is Script, Deployed {

    EtherFiRestaker constant etherFiRestaker = EtherFiRestaker(payable(ETHERFI_RESTAKER));

    function run() external {
        IDelegationManager delegationManager = etherFiRestaker.eigenLayerDelegationManager();
        address lido = address(etherFiRestaker.lido());
        uint32 delayBlocks = delegationManager.minWithdrawalDelayBlocks();

        console2.log("=== EtherFi Restaker: Complete Queued stETH Withdrawals ===");
        console2.log("Restaker:", address(etherFiRestaker));
        console2.log("Current block:", block.number);
        console2.log("Min withdrawal delay blocks:", delayBlocks);
        console2.log("");

        // Fetch all pending withdrawal roots tracked by the restaker
        bytes32[] memory allRoots = etherFiRestaker.pendingWithdrawalRoots();
        console2.log("Total pending withdrawal roots:", allRoots.length);
        require(allRoots.length > 0, "No pending withdrawal roots");

        // Filter for completable roots (past the delay)
        uint256 completableCount = 0;
        bool[] memory isCompletable = new bool[](allRoots.length);

        for (uint256 i = 0; i < allRoots.length; i++) {
            (IDelegationManager.Withdrawal memory w,) = delegationManager.getQueuedWithdrawal(allRoots[i]);

            bool pastDelay = block.number >= uint256(w.startBlock) + uint256(delayBlocks);
            isCompletable[i] = pastDelay;

            console2.log("---");
            console2.log("  root:");
            console2.logBytes32(allRoots[i]);
            console2.log("  startBlock:", w.startBlock);
            console2.log("  completableAtBlock:", uint256(w.startBlock) + uint256(delayBlocks));
            console2.log("  ready:", pastDelay ? "YES" : "NO");

            if (pastDelay) completableCount++;
        }

        console2.log("");
        console2.log("Completable withdrawals:", completableCount, "of", allRoots.length);
        require(completableCount > 0, "No withdrawals ready to complete yet");

        // Build arrays for only the completable withdrawals
        IDelegationManager.Withdrawal[] memory withdrawals = new IDelegationManager.Withdrawal[](completableCount);
        IERC20[][] memory tokens = new IERC20[][](completableCount);

        uint256 idx = 0;
        for (uint256 i = 0; i < allRoots.length; i++) {
            if (!isCompletable[i]) continue;

            (IDelegationManager.Withdrawal memory w,) = delegationManager.getQueuedWithdrawal(allRoots[i]);
            withdrawals[idx] = w;

            tokens[idx] = new IERC20[](w.strategies.length);
            for (uint256 j = 0; j < w.strategies.length; j++) {
                tokens[idx][j] = w.strategies[j].underlyingToken();
            }
            idx++;
        }

        // Log calldata for Gnosis Safe
        bytes memory callData = abi.encodeWithSelector(
            EtherFiRestaker.completeQueuedWithdrawals.selector,
            withdrawals,
            tokens
        );
        console2.log("");
        console2.log("=== completeQueuedWithdrawals calldata ===");
        console2.log("Target:", address(etherFiRestaker));
        console2.logBytes(callData);

        // Simulate the completion on fork
        console2.log("");
        console2.log("=== Simulating completion on fork ===");
        uint256 stEthBefore = IERC20(lido).balanceOf(address(etherFiRestaker));

        vm.prank(ETHERFI_OPERATING_ADMIN);
        etherFiRestaker.completeQueuedWithdrawals(withdrawals, tokens);

        uint256 stEthAfter = IERC20(lido).balanceOf(address(etherFiRestaker));
        console2.log("stETH received by restaker:", stEthAfter - stEthBefore);
        console2.log("Remaining pending roots:", etherFiRestaker.pendingWithdrawalRoots().length);
        console2.log("Remaining restaked stETH:", etherFiRestaker.getRestakedAmount(lido));
        console2.log("Simulation successful");

        // bytes memory callData2 = abi.encodeWithSignature(
        //     "stEthRequestWithdrawal(uint256)",
        //     50000 ether
        // );
        // console2.log("");
        // console2.log("=== stEthRequestWithdrawal calldata ===");
        // console2.log("Target:", address(etherFiRestaker));
        // console2.logBytes(callData2);

        // vm.prank(ETHERFI_OPERATING_ADMIN);
        // etherFiRestaker.stEthRequestWithdrawal(50000 ether);
    }
}
