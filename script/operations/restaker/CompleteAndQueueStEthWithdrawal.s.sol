// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "forge-std/Script.sol";
import "forge-std/console2.sol";
import "forge-std/Test.sol";
import {Utils} from "../../utils/utils.sol";
import {EtherFiRestaker} from "../../../src/EtherFiRestaker.sol";
import {IDelegationManager, IDelegationManagerTypes} from "../../../src/eigenlayer-interfaces/IDelegationManager.sol";
import {IStrategy} from "../../../src/eigenlayer-interfaces/IStrategy.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "lib/BucketLimiter.sol";

// Complete a specific queued EigenLayer withdrawal on the EtherFiRestaker
// (root 0x1fd5b821…4b214a, expecting ~205k stETH back into the restaker),
// then immediately queue a Lido unstake of 145k stETH.
//
// Both EtherFiRestaker.completeQueuedWithdrawals and
// EtherFiRestaker.stEthRequestWithdrawal are `onlyAdmin`. admins[] maps
// ETHERFI_OPERATING_ADMIN -> true, so both calls can be made directly by
// the operating admin Safe (no timelock).
//
// Emits one Safe JSON: complete-and-queue-steth-withdrawal.json
// containing the 2-txn batch.
//
//   forge script script/operations/restaker/CompleteAndQueueStEthWithdrawal.s.sol --fork-url $MAINNET_RPC_URL -vvvv
contract CompleteAndQueueStEthWithdrawal is Script, Utils, Test {
    EtherFiRestaker constant RESTAKER = EtherFiRestaker(payable(ETHERFI_RESTAKER));
    IDelegationManager constant DM = IDelegationManager(EIGENLAYER_DELEGATION_MANAGER);

    // stETH (Lido)
    address constant STETH = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;
    // EigenLayer stETH strategy
    address constant STETH_STRATEGY = 0x93c4b944D05dfe6df7645A86cd2206016c51564D;

    // The target withdrawal root to complete
    bytes32 constant TARGET_ROOT =
        0x1fd5b821fdc304f71ac528e188af2b303c2aced2f3e3516e89cab4ebe34b214a;

    // Amount of stETH to queue for Lido unstaking after completion.
    // Leaves headroom in the restaker to cover pending whale redemption
    // (~65.6k stETH for 60k weETH at current rate) plus buffer.
    uint256 constant STETH_UNSTAKE_AMOUNT = 138_000 ether;

    // --------------------------------------------------------------------
    // Decoded from SlashingWithdrawalQueued event in queueing tx
    // 0xe5c3b4a51b1b0fc30ffe5e36ca5652b1b198b72d8a4de5e247915357783c66cc
    // Note: delegatedTo is the operator at queue time, NOT the current one
    // (restaker has since re-delegated). The struct hash uses the queue-time
    // value, so we must preserve it exactly.
    // --------------------------------------------------------------------
    address constant W_STAKER      = ETHERFI_RESTAKER;
    address constant W_DELEGATED   = 0x5ACCC90436492F24E6aF278569691e2c942A676d;
    address constant W_WITHDRAWER  = ETHERFI_RESTAKER;
    uint256 constant W_NONCE       = 5;
    uint32  constant W_START_BLOCK = 24_845_451;
    uint256 constant W_SCALED_SHARES = 188_467_287_078_862_890_369_933;

    string constant OUTPUT_DIR = "script/operations/restaker";
    string constant OUTPUT_FILE = "complete-and-queue-steth-withdrawal.json";

    function run() external {
        console2.log("====================================================");
        console2.log("=== Complete queued withdrawal + queue stETH unstake");
        console2.log("====================================================");

        // Sanity: root must still be pending on the restaker
        require(
            RESTAKER.isPendingWithdrawal(TARGET_ROOT),
            "TARGET_ROOT not in restaker's pendingWithdrawalRoots"
        );

        IDelegationManagerTypes.Withdrawal memory w = _buildWithdrawal();
        IERC20[][] memory tokens = _buildTokens();

        // Verify struct hashes to the expected root before writing Safe JSON
        bytes32 computedRoot = DM.calculateWithdrawalRoot(w);
        console2.log("computed root:");
        console2.logBytes32(computedRoot);
        console2.log("expected root:");
        console2.logBytes32(TARGET_ROOT);
        require(computedRoot == TARGET_ROOT, "Withdrawal struct does not hash to TARGET_ROOT - fill constants correctly");

        _writeSafeBatch(w, tokens);
        _simulate(w, tokens);
    }

    // ------------------------------------------------------------------
    // Construction
    // ------------------------------------------------------------------

    function _buildWithdrawal()
        internal
        pure
        returns (IDelegationManagerTypes.Withdrawal memory w)
    {
        IStrategy[] memory strategies = new IStrategy[](1);
        strategies[0] = IStrategy(STETH_STRATEGY);

        uint256[] memory scaledShares = new uint256[](1);
        scaledShares[0] = W_SCALED_SHARES;

        w = IDelegationManagerTypes.Withdrawal({
            staker: W_STAKER,
            delegatedTo: W_DELEGATED,
            withdrawer: W_WITHDRAWER,
            nonce: W_NONCE,
            startBlock: W_START_BLOCK,
            strategies: strategies,
            scaledShares: scaledShares
        });
    }

    function _buildTokens() internal pure returns (IERC20[][] memory tokens) {
        tokens = new IERC20[][](1);
        tokens[0] = new IERC20[](1);
        tokens[0][0] = IERC20(STETH);
    }

    // ------------------------------------------------------------------
    // Safe JSON
    // ------------------------------------------------------------------

    function _writeSafeBatch(
        IDelegationManagerTypes.Withdrawal memory w,
        IERC20[][] memory tokens
    ) internal {
        IDelegationManagerTypes.Withdrawal[] memory ws = new IDelegationManagerTypes.Withdrawal[](1);
        ws[0] = w;

        address[] memory targets = new address[](2);
        uint256[] memory values  = new uint256[](2);
        bytes[]   memory data    = new bytes[](2);

        targets[0] = address(RESTAKER);
        values[0]  = 0;
        data[0]    = abi.encodeWithSelector(
            EtherFiRestaker.completeQueuedWithdrawals.selector, ws, tokens
        );

        targets[1] = address(RESTAKER);
        values[1]  = 0;
        data[1]    = abi.encodeWithSignature(
            "stEthRequestWithdrawal(uint256)", STETH_UNSTAKE_AMOUNT
        );

        writeSafeJson(
            OUTPUT_DIR,
            OUTPUT_FILE,
            ETHERFI_OPERATING_ADMIN,
            targets,
            values,
            data,
            1
        );
    }

    // ------------------------------------------------------------------
    // Fork simulation
    // ------------------------------------------------------------------

    function _simulate(
        IDelegationManagerTypes.Withdrawal memory w,
        IERC20[][] memory tokens
    ) internal {
        IDelegationManagerTypes.Withdrawal[] memory ws = new IDelegationManagerTypes.Withdrawal[](1);
        ws[0] = w;

        uint256 stEthBefore = IERC20(STETH).balanceOf(address(RESTAKER));
        console2.log("restaker stETH before:", stEthBefore / 1e18);

        // EL withdrawal delay is 100,800 blocks (~14d). Roll past it so the
        // fork simulation succeeds; real Safe execution will already satisfy
        // this by the time txns land.
        uint256 minCompletableBlock = uint256(W_START_BLOCK) + 100_800 + 1;
        if (block.number < minCompletableBlock) {
            vm.roll(minCompletableBlock);
            vm.warp(block.timestamp + 14 days);
        }

        vm.startPrank(ETHERFI_OPERATING_ADMIN);
        RESTAKER.completeQueuedWithdrawals(ws, tokens);
        uint256 stEthAfterComplete = IERC20(STETH).balanceOf(address(RESTAKER));
        console2.log("restaker stETH after complete:", stEthAfterComplete / 1e18);
        console2.log("stETH received:", (stEthAfterComplete - stEthBefore) / 1e18);

        uint256[] memory reqIds = RESTAKER.stEthRequestWithdrawal(STETH_UNSTAKE_AMOUNT);
        vm.stopPrank();

        uint256 stEthAfterQueue = IERC20(STETH).balanceOf(address(RESTAKER));
        console2.log("restaker stETH after queue:", stEthAfterQueue / 1e18);
        console2.log("stETH queued for Lido unstake:", STETH_UNSTAKE_AMOUNT / 1e18);
        console2.log("Lido request count:", reqIds.length);

        assertFalse(
            RESTAKER.isPendingWithdrawal(TARGET_ROOT),
            "root should be removed from pendingWithdrawalRoots"
        );
        // Lido share rounding introduces a few wei of dust across 145 requests.
        assertApproxEqAbs(
            stEthAfterQueue,
            stEthAfterComplete - STETH_UNSTAKE_AMOUNT,
            1000,
            "stETH balance should drop by ~Lido-queued amount"
        );

        console2.log("Simulation passed.");
    }
}
