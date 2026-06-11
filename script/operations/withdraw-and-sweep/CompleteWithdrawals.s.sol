// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "forge-std/Script.sol";
import "forge-std/console2.sol";

import {IEtherFiNodesManager} from "../../../src/interfaces/IEtherFiNodesManager.sol";
import {IRoleRegistry} from "../../../src/interfaces/IRoleRegistry.sol";
import {Utils} from "../../utils/utils.sol";

/// @title CompleteWithdrawals
/// @notice Calls EtherFiNodesManager.completeQueuedETHWithdrawals(node, false) for 22
///         EtherFiNodes from the EIGENLAYER_ADMIN EOA. ETH lands on each node, which is
///         then swept to the LiquidityPool by SweepFunds.s.sol via the operating timelock.
///
/// Caller MUST hold ETHERFI_NODES_MANAGER_EIGENLAYER_ADMIN_ROLE.
/// Expected caller: 0x12582A27E5e19492b4FcD194a60F8f5e1aa31B0F
///
/// Usage:
///   # Simulate on fork (no broadcast)
///   forge script script/operations/withdraw-and-sweep/CompleteWithdrawals.s.sol:CompleteWithdrawals \
///     --fork-url $MAINNET_RPC_URL -vvvv
///
///   # Actual execution
///   PRIVATE_KEY=0x... forge script script/operations/withdraw-and-sweep/CompleteWithdrawals.s.sol:CompleteWithdrawals \
///     --rpc-url $MAINNET_RPC_URL --broadcast -vvvv
contract CompleteWithdrawals is Script, Utils {
    IEtherFiNodesManager constant nodesManager = IEtherFiNodesManager(ETHERFI_NODES_MANAGER);

    address constant EXPECTED_CALLER = 0x12582A27E5e19492b4FcD194a60F8f5e1aa31B0F;
    bytes32 constant ROLE = keccak256("ETHERFI_NODES_MANAGER_EIGENLAYER_ADMIN_ROLE");

    function nodes() internal pure returns (address[] memory n) {
        n = new address[](22);
        n[0]  = 0x4Cb9384E3cc72f9302288f64edadE772d7F2DD06;
        n[1]  = 0x555C1a885F98968874e7b69e96937A59182ab8dA;
        n[2]  = 0x1dF4fd06bB3866D7d66e0Db8428B24fd829B2e9b;
        n[3]  = 0x4c0456404760794A5b69550E5B76Fc0265710DDB;
        n[4]  = 0x92316Ab4BEe3662709DD6a96ea19B06692409B2E;
        n[5]  = 0x492f1ABda3efF51eEeBa1a4baC3801Da773AaA0E;
        n[6]  = 0x0A72F682e70F3dc64a3701b684d3Be09FC7A9D3a;
        n[7]  = 0x859ee23A15039b52230F90306c5529845d5E4806;
        n[8]  = 0x3d3124cA9740bBdd46ed2AC943a9a4a3dEAFba4a;
        n[9]  = 0x828d2f327b985CE817B18DDB6dfCC299ca93A692;
        n[10] = 0x75d2672CB618F47bC1CAa417e681100090fDBB99;
        n[11] = 0xdd2b96f0e708F2DE5aF69CBad82824330AC182eE;
        n[12] = 0x6aeE24AaA432ab826f9eDD7F33dFC4Fd15a50b37;
        n[13] = 0xc5eD912cA6DB7b41De4ef3632Fa0A5641E42BF09;
        n[14] = 0xb9d000815899360ECfaD44Cd3C150103B37fCE28;
        n[15] = 0x1adF94c9cABeEdb88149Ad8Dc54785507d243AAe;
        n[16] = 0x5F1245A3ed7e93D87493EF1b152767F26F452956;
        n[17] = 0x9335F3c4d0eFDFf9eb5593D94EAd40D3bBd64461;
        n[18] = 0xA74969cc2571C93b48E1b3f3330eef187d34c399;
        n[19] = 0x5ff1bdc8e6A9E22C2d173574Cb0Ed22FbD2ddBA6;
        n[20] = 0x4e7A000995358e75010e1cD361Dbd73a365feC74;
        n[21] = 0x6847c6c2e10d1315A172869C49Eb5c7BbCD9b55A;
    }

    function run() external {
        address[] memory list = nodes();

        bool broadcasting = vm.envOr("BROADCAST", false);
        address caller = EXPECTED_CALLER;
        uint256 pk;
        if (broadcasting) {
            pk = vm.envUint("PRIVATE_KEY");
            caller = vm.addr(pk);
        }

        console2.log("=== COMPLETE QUEUED ETH WITHDRAWALS ===");
        console2.log("Manager:", ETHERFI_NODES_MANAGER);
        console2.log("Caller:", caller);
        console2.log("Expected EOA:", EXPECTED_CALLER);
        if (broadcasting && caller != EXPECTED_CALLER) {
            console2.log("WARNING: caller does not match expected admin EOA");
        }
        _checkRole(caller);

        uint256 lpBefore = LIQUIDITY_POOL.balance;
        uint256[] memory before = new uint256[](list.length);
        for (uint256 i = 0; i < list.length; i++) before[i] = list[i].balance;

        if (broadcasting) {
            vm.startBroadcast(pk);
        } else {
            vm.startPrank(EXPECTED_CALLER);
        }

        for (uint256 i = 0; i < list.length; i++) {
            uint256 gasBefore = gasleft();
            nodesManager.completeQueuedETHWithdrawals(list[i], false);
            uint256 gasUsed = gasBefore - gasleft();
            console2.log(list[i], "gas:", gasUsed);
        }

        if (broadcasting) vm.stopBroadcast(); else vm.stopPrank();

        console2.log("\n--- DELTAS ---");
        uint256 totalDelta;
        for (uint256 i = 0; i < list.length; i++) {
            uint256 delta = list[i].balance - before[i];
            totalDelta += delta;
            console2.log(list[i], "node ETH delta:", delta);
        }
        console2.log("LP balance delta:", LIQUIDITY_POOL.balance - lpBefore);
        console2.log("Total node delta:", totalDelta);
    }

    function _checkRole(address account) internal view {
        (bool ok, bytes memory data) = ETHERFI_NODES_MANAGER.staticcall(
            abi.encodeWithSignature("roleRegistry()")
        );
        if (!ok || data.length < 32) {
            console2.log("Role check skipped");
            return;
        }
        IRoleRegistry rr = IRoleRegistry(abi.decode(data, (address)));
        bool has = rr.hasRole(ROLE, account);
        console2.log(has ? "Role check PASSED" : "Role check FAILED - tx will revert");
    }
}
