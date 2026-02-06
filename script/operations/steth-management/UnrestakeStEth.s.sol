// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "forge-std/Script.sol";
import "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Deployed} from "../../deploys/Deployed.s.sol";
import {EtherFiRestaker} from "../../../src/EtherFiRestaker.sol";
import {IDelegationManager} from "../../../src/eigenlayer-interfaces/IDelegationManager.sol";

// Full un-restake (all stETH restaked in EigenLayer):
//   FULL_WITHDRAWAL=true forge script script/operations/steth-claim-withdrawals/UnrestakeStEth.s.sol --fork-url $MAINNET_RPC_URL -vvvv
//
// Partial un-restake (amount in ether):
//   AMOUNT=100 forge script script/operations/steth-claim-withdrawals/UnrestakeStEth.s.sol --fork-url $MAINNET_RPC_URL -vvvv

contract UnrestakeStEth is Script, Deployed {

    EtherFiRestaker constant etherFiRestaker = EtherFiRestaker(payable(ETHERFI_RESTAKER));

    function run() external {
        address lido = address(etherFiRestaker.lido());

        bool fullWithdrawal = vm.envOr("FULL_WITHDRAWAL", false);
        uint256 amountInEther = vm.envOr("AMOUNT", uint256(0));
        require(fullWithdrawal || amountInEther > 0, "Set FULL_WITHDRAWAL=true or AMOUNT=<ether>");

        uint256 restakedAmount = etherFiRestaker.getRestakedAmount(lido);
        uint256 amount = fullWithdrawal ? restakedAmount : amountInEther * 1 ether;

        console2.log("stETH restaked in EigenLayer:", restakedAmount);
        console2.log("Unrestake amount:", amount);
        console2.log("Mode:", fullWithdrawal ? "full" : "partial");
        console2.log("");

        bytes32[] memory withdrawalRoots = _queueWithdrawals(lido, amount);
        _warpPastDelay();
        _completeWithdrawals(lido, withdrawalRoots);
    }

    // ========================================================
    // Step 1: Queue EigenLayer Withdrawal
    // ========================================================
    function _queueWithdrawals(address _lido, uint256 _amount) internal returns (bytes32[] memory withdrawalRoots) {
        console2.log("=== Step 1: Queue EigenLayer Withdrawal ===");

        vm.prank(ETHERFI_OPERATING_ADMIN);
        withdrawalRoots = etherFiRestaker.queueWithdrawals(_lido, _amount);

        console2.log("Queued", withdrawalRoots.length, "withdrawal(s):");
        for (uint256 i = 0; i < withdrawalRoots.length; i++) {
            console2.log("  root:");
            console2.logBytes32(withdrawalRoots[i]);
        }

        bytes memory callData = abi.encodeWithSelector(
            EtherFiRestaker.queueWithdrawals.selector, _lido, _amount
        );
        console2.log("");
        console2.log("=== queueWithdrawals calldata ===");
        console2.log("Target:", address(etherFiRestaker));
        console2.logBytes(callData);
    }

    // ========================================================
    // Step 2: Warp past EigenLayer withdrawal delay
    // ========================================================
    function _warpPastDelay() internal {
        console2.log("");
        console2.log("=== Step 2: Fast-forward past EigenLayer delay ===");

        uint32 delayBlocks = etherFiRestaker.eigenLayerDelegationManager().minWithdrawalDelayBlocks();
        console2.log("MIN_WITHDRAWAL_DELAY_BLOCKS:", delayBlocks);

        vm.roll(block.number + delayBlocks + 1);
        vm.warp(block.timestamp + (uint256(delayBlocks) + 1) * 12); // ~12s per block
        console2.log("Warped to block:", block.number);
    }

    // ========================================================
    // Step 3: Complete Queued Withdrawals
    // ========================================================
    function _completeWithdrawals(address _lido, bytes32[] memory _roots) internal {
        console2.log("");
        console2.log("=== Step 3: Complete Queued Withdrawals ===");

        IDelegationManager delegationManager = etherFiRestaker.eigenLayerDelegationManager();

        IDelegationManager.Withdrawal[] memory withdrawals = new IDelegationManager.Withdrawal[](_roots.length);
        IERC20[][] memory tokens = new IERC20[][](_roots.length);

        for (uint256 i = 0; i < _roots.length; i++) {
            (IDelegationManager.Withdrawal memory w,) = delegationManager.getQueuedWithdrawal(_roots[i]);
            withdrawals[i] = w;

            tokens[i] = new IERC20[](w.strategies.length);
            for (uint256 j = 0; j < w.strategies.length; j++) {
                tokens[i][j] = w.strategies[j].underlyingToken();
            }
        }

        // Log complete calldata
        bytes memory callData = abi.encodeWithSelector(
            EtherFiRestaker.completeQueuedWithdrawals.selector,
            withdrawals,
            tokens
        );
        console2.log("=== completeQueuedWithdrawals calldata ===");
        console2.log("Target:", address(etherFiRestaker));
        console2.logBytes(callData);

        // Simulate the completion
        console2.log("");
        console2.log("=== Simulating completion on fork ===");
        uint256 stEthBefore = IERC20(_lido).balanceOf(address(etherFiRestaker));

        vm.prank(ETHERFI_OPERATING_ADMIN);
        etherFiRestaker.completeQueuedWithdrawals(withdrawals, tokens);

        uint256 stEthAfter = IERC20(_lido).balanceOf(address(etherFiRestaker));
        console2.log("stETH received by restaker:", stEthAfter - stEthBefore);
        console2.log("Remaining restaked stETH:", etherFiRestaker.getRestakedAmount(_lido));
        console2.log("Simulation successful");
    }
}
