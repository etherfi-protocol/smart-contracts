// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Utils} from "../../utils/utils.sol";
import {EtherFiRestaker} from "../../../src/EtherFiRestaker.sol";
import {IDelegationManager} from "../../../src/eigenlayer-interfaces/IDelegationManager.sol";
import {ISignatureUtilsMixinTypes} from "../../../src/eigenlayer-interfaces/ISignatureUtilsMixin.sol";

// Redelegates EtherFiRestaker's stETH from current operator to ether.fi-17.
//
// Two-step process (two separate Safe transactions):
//
// Step 1 — Undelegate (queues withdrawal of all restaked stETH). Writes Gnosis Safe JSON for Operating Admin:
//   STEP=1 forge script script/operations/steth-management/RedelegateStEth.s.sol --fork-url $MAINNET_RPC_URL -vvvv
// Optional: OUTPUT_FILENAME (default redelegate-steth-step1-gnosis.json under script/operations/steth-management/),
//           CHAIN_ID (default block.chainid), SAFE_ADDRESS (default ETHERFI_OPERATING_ADMIN)
//
// Step 2 — Complete withdrawal + redelegate + re-deposit (after EigenLayer delay). Writes one Gnosis batch JSON
// (3 txs: completeQueuedWithdrawals, delegateTo, depositIntoStrategy) for Operating Admin:
//   STEP=2 forge script script/operations/steth-management/RedelegateStEth.s.sol --fork-url $MAINNET_RPC_URL -vvvv
// Optional: OUTPUT_FILENAME (default redelegate-steth-step2-gnosis.json), CHAIN_ID, SAFE_ADDRESS (same as step 1)

contract RedelegateStEth is Utils {

    EtherFiRestaker constant restaker = EtherFiRestaker(payable(ETHERFI_RESTAKER));

    // ether.fi-17 operator
    address constant NEW_OPERATOR = 0x4eDf87Cd9450eFB42B735b48eC837afD3DbBd348;

    function run() external {
        uint256 step = vm.envOr("STEP", uint256(0));
        require(step == 1 || step == 2, "Set STEP=1 or STEP=2");

        address lido = address(restaker.lido());
        IDelegationManager dm = restaker.eigenLayerDelegationManager();

        _logCurrentState(lido, dm);

        if (step == 1) {
            _step1_undelegate(dm);
        } else {
            _step2_completeAndRedelegate(lido, dm);
        }
    }

    // ================================================================
    // Step 1: Undelegate from current operator
    // ================================================================
    function _step1_undelegate(IDelegationManager dm) internal {
        console2.log("");
        console2.log("========================================");
        console2.log("  STEP 1: Undelegate from current operator");
        console2.log("========================================");

        address currentOperator = dm.delegatedTo(address(restaker));
        console2.log("Current operator:", currentOperator);
        console2.log("New operator:    ", NEW_OPERATOR);
        console2.log("");

        vm.prank(ETHERFI_OPERATING_ADMIN);
        bytes32[] memory roots = restaker.undelegate();

        console2.log("Queued", roots.length, "withdrawal(s):");
        for (uint256 i = 0; i < roots.length; i++) {
            console2.log("  root:");
            console2.logBytes32(roots[i]);
        }

        bytes memory callData = abi.encodeWithSelector(
            EtherFiRestaker.undelegate.selector
        );

        uint256 chainId = vm.envOr("CHAIN_ID", block.chainid);
        address safeAddress = vm.envOr("SAFE_ADDRESS", ETHERFI_OPERATING_ADMIN);
        string memory filename =
            vm.envOr("OUTPUT_FILENAME", string("redelegate-steth-step1-gnosis.json"));

        console2.log("");
        console2.log("=== Gnosis Safe JSON (Operating Admin) ===");
        console2.log("Safe:", safeAddress);
        writeSafeJson(
            "script/operations/steth-management",
            filename,
            safeAddress,
            address(restaker),
            0,
            callData,
            chainId
        );
        console2.log("");
        console2.log("=== Safe transaction (same as JSON) ===");
        console2.log("To:", address(restaker));
        console2.log("Value: 0");
        console2.log("Calldata:");
        console2.logBytes(callData);

        // Show delay info
        uint32 delayBlocks = dm.minWithdrawalDelayBlocks();
        console2.log("");
        console2.log("Withdrawal delay blocks:", delayBlocks);
        console2.log("Estimated delay: ~", (uint256(delayBlocks) * 12) / 3600, "hours");
        console2.log("");
        console2.log("Run STEP=2 after the delay has passed.");
    }

    // ================================================================
    // Step 2: Complete withdrawals + delegateTo + depositIntoStrategy
    // ================================================================
    function _step2_completeAndRedelegate(address lido, IDelegationManager dm) internal {
        console2.log("");
        console2.log("========================================");
        console2.log("  STEP 2: Complete + Redelegate + Deposit");
        console2.log("========================================");

        (bytes memory completeCalldata, bytes memory delegateCalldata, bytes memory depositCalldata) =
            _step2_simulateAndEncodeCalldata(lido, dm);

        _writeStep2GnosisBatch(completeCalldata, delegateCalldata, depositCalldata);

        console2.log("");
        console2.log("=== TX 1: completeQueuedWithdrawals ===");
        console2.logBytes(completeCalldata);
        console2.log("=== TX 2: delegateTo ===");
        console2.logBytes(delegateCalldata);
        console2.log("=== TX 3: depositIntoStrategy ===");
        console2.logBytes(depositCalldata);

        _logCurrentState(lido, dm);
    }

    /// @dev Fork simulation to derive deposit amount; returns calldata for the three Safe txs in order.
    function _step2_simulateAndEncodeCalldata(address lido, IDelegationManager dm)
        internal
        returns (bytes memory completeCalldata, bytes memory delegateCalldata, bytes memory depositCalldata)
    {
        bytes32[] memory pendingRoots = restaker.pendingWithdrawalRoots();
        require(pendingRoots.length > 0, "No pending withdrawals to complete");

        console2.log("Pending withdrawal roots:", pendingRoots.length);

        IDelegationManager.Withdrawal[] memory withdrawals = new IDelegationManager.Withdrawal[](pendingRoots.length);
        IERC20[][] memory tokens = new IERC20[][](pendingRoots.length);

        for (uint256 i = 0; i < pendingRoots.length; i++) {
            (IDelegationManager.Withdrawal memory w,) = dm.getQueuedWithdrawal(pendingRoots[i]);
            withdrawals[i] = w;
            tokens[i] = new IERC20[](w.strategies.length);
            for (uint256 j = 0; j < w.strategies.length; j++) {
                tokens[i][j] = w.strategies[j].underlyingToken();
            }
        }

        completeCalldata = abi.encodeWithSelector(
            EtherFiRestaker.completeQueuedWithdrawals.selector,
            withdrawals,
            tokens
        );

        ISignatureUtilsMixinTypes.SignatureWithExpiry memory emptySig = ISignatureUtilsMixinTypes.SignatureWithExpiry({
            signature: "",
            expiry: 0
        });
        delegateCalldata = abi.encodeWithSelector(
            EtherFiRestaker.delegateTo.selector,
            NEW_OPERATOR,
            emptySig,
            bytes32(0)
        );

        uint256 stEthBefore = IERC20(lido).balanceOf(address(restaker));

        vm.prank(ETHERFI_OPERATING_ADMIN);
        restaker.completeQueuedWithdrawals(withdrawals, tokens);

        uint256 stEthAfter = IERC20(lido).balanceOf(address(restaker));
        console2.log("stETH received:", stEthAfter - stEthBefore);

        uint256 depositAmount = IERC20(lido).balanceOf(address(restaker));
        console2.log("Deposit amount (for re-deposit tx):", depositAmount);

        depositCalldata = abi.encodeWithSelector(
            EtherFiRestaker.depositIntoStrategy.selector,
            lido,
            depositAmount
        );

        vm.prank(ETHERFI_OPERATING_ADMIN);
        restaker.delegateTo(NEW_OPERATOR, emptySig, bytes32(0));
        console2.log("Delegated to:", NEW_OPERATOR);

        vm.prank(ETHERFI_OPERATING_ADMIN);
        uint256 shares = restaker.depositIntoStrategy(lido, depositAmount);
        console2.log("Shares received:", shares);
    }

    function _writeStep2GnosisBatch(
        bytes memory completeCalldata,
        bytes memory delegateCalldata,
        bytes memory depositCalldata
    ) internal {
        uint256 chainId = vm.envOr("CHAIN_ID", block.chainid);
        address safeAddress = vm.envOr("SAFE_ADDRESS", ETHERFI_OPERATING_ADMIN);
        string memory filename =
            vm.envOr("OUTPUT_FILENAME", string("redelegate-steth-step2-gnosis.json"));

        SafeTx[] memory step2Txs = new SafeTx[](3);
        step2Txs[0] = SafeTx({to: address(restaker), value: 0, data: completeCalldata});
        step2Txs[1] = SafeTx({to: address(restaker), value: 0, data: delegateCalldata});
        step2Txs[2] = SafeTx({to: address(restaker), value: 0, data: depositCalldata});

        console2.log("");
        console2.log("=== Gnosis Safe batch JSON (Operating Admin, 3 txs) ===");
        console2.log("Safe:", safeAddress);
        writeSafeJson("script/operations/steth-management", filename, safeAddress, step2Txs, chainId);
    }

    function _logCurrentState(address lido, IDelegationManager dm) internal view {
        console2.log("");
        console2.log("=== Current State ===");
        console2.log("Delegated:", restaker.isDelegated());
        console2.log("Delegated to:", dm.delegatedTo(address(restaker)));
        console2.log("Restaked stETH:", restaker.getRestakedAmount(lido));
        console2.log("Held stETH:    ", IERC20(lido).balanceOf(address(restaker)));
        console2.log("Pending roots: ", restaker.pendingWithdrawalRoots().length);
    }
}
