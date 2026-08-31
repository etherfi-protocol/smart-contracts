// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "forge-std/Script.sol";
import "forge-std/console2.sol";
import {Deployed} from "@scripts/deploys/Deployed.s.sol";

interface IAvsOperatorManager {
    function adminForwardCall(uint256 id, address target, bytes4 selector, bytes calldata args) external;
    function avsOperators(uint256 id) external view returns (address);
    function nextAvsOperatorId() external view returns (uint256);
}

interface IAVSDirectory {
    function avsOperatorStatus(address avs, address operator) external view returns (uint8);
}

/**
 * @title AvsDeregistration
 * @notice Deregisters ether.fi's AvsOperator proxies from their EigenLayer AVSs.
 *
 * Routing: direct calls from ETHERFI_OPERATING_ADMIN (4-of-7 Safe), no timelock.
 * `adminForwardCall` is gated by OPERATION_MULTISIG_ROLE, which that Safe holds and the
 * UPGRADE_TIMELOCK does not, so this cannot be batched with a timelock upgrade.
 *
 * All registrations are on the legacy AVSDirectory. `deregisterOperatorFromAVS` there is
 * AVS-only, so each deregistration is driven operator-side through the AVS's own middleware
 * and forwarded by the manager. Middleware and arguments differ per AVS, so the call list is
 * enumerated and fork-verified offline and committed as avs-deregistration-calls.json.
 *
 * command:
 * forge script script/upgrades/avs-deregistration/AvsDeregistration.s.sol:AvsDeregistration \
 *   --fork-url $MAINNET_RPC_URL -vvvv
 */
contract AvsDeregistration is Script, Deployed {
    IAvsOperatorManager constant manager = IAvsOperatorManager(ETHERFI_AVS_OPERATORS_MANAGER);
    IAVSDirectory constant avsDirectory = IAVSDirectory(0x135DDa560e946695d6f155dACaFC6f1F25C1F5AF);
    address constant MULTISEND_CALL_ONLY = 0x40A2aCCbd92BCA938b02010E17A5b8929b49130D;

    /// @dev per-Safe-tx gas ceiling; EIP-7825 caps a tx at 16,777,216
    uint256 constant BATCH_GAS_CAP = 12_000_000;
    /// @dev Safe execTransaction + MultiSend overhead charged per inner call
    uint256 constant PER_CALL_OVERHEAD = 30_000;

    struct Call {
        uint256 operatorId;
        address avs;
        string avsName;
        address target;
        bytes4 selector;
        bytes args;
        /// @dev real anvil tx gas, measured in sequence. Batches are sized on this, not on
        ///      gasleft() inside the script, which excludes intrinsic and calldata cost.
        uint256 gasUsed;
    }

    Call[] internal calls;

    function run() public {
        _loadCalls();
        console2.log("loaded calls:", calls.length);

        _simulateAll();
        _verifyAllDeregistered();
        _logBatches();
    }

    function _loadCalls() internal {
        string memory json = vm.readFile("script/upgrades/avs-deregistration/avs-deregistration-calls.json");
        uint256 n = vm.parseJsonUint(json, ".blockNumber");
        console2.log("enumerated at block:", n);

        for (uint256 i = 0; ; i++) {
            string memory p = string.concat(".calls[", vm.toString(i), "]");
            if (!vm.keyExistsJson(json, p)) break;
            calls.push(
                Call({
                    operatorId: vm.parseJsonUint(json, string.concat(p, ".operatorId")),
                    avs: vm.parseJsonAddress(json, string.concat(p, ".avs")),
                    avsName: vm.parseJsonString(json, string.concat(p, ".avsName")),
                    target: vm.parseJsonAddress(json, string.concat(p, ".target")),
                    selector: bytes4(vm.parseJsonBytes(json, string.concat(p, ".selector"))),
                    args: vm.parseJsonBytes(json, string.concat(p, ".args")),
                    gasUsed: vm.parseJsonUint(json, string.concat(p, ".gasUsed"))
                })
            );
        }
    }

    /// @dev runs every call in order from the Operating Safe
    function _simulateAll() internal {
        for (uint256 i = 0; i < calls.length; i++) {
            Call memory c = calls[i];
            vm.prank(ETHERFI_OPERATING_ADMIN);
            manager.adminForwardCall(c.operatorId, c.target, c.selector, c.args);
        }
        console2.log("all calls succeeded");
    }

    /// @dev every (operator, avs) pair touched must now read UNREGISTERED on the AVSDirectory
    function _verifyAllDeregistered() internal view {
        for (uint256 i = 0; i < calls.length; i++) {
            address operator = manager.avsOperators(calls[i].operatorId);
            uint8 status = avsDirectory.avsOperatorStatus(calls[i].avs, operator);
            if (status != 0) {
                console2.log("[STILL REGISTERED]", calls[i].avsName, calls[i].operatorId);
                revert("operator still registered after deregistration");
            }
        }
        console2.log("[OK] every touched pair reads UNREGISTERED on the AVSDirectory");
    }

    /// @dev greedy-packs the calls into Safe txs under the gas cap and logs each MultiSend payload
    function _logBatches() internal view {
        console2.log("");
        console2.log("=== Safe txs (MultiSendCallOnly, operation = 1) ===");
        console2.log("safe:      ", ETHERFI_OPERATING_ADMIN);
        console2.log("to:        ", MULTISEND_CALL_ONLY);
        console2.log("gas cap:   ", BATCH_GAS_CAP);
        console2.log("");

        uint256 start;
        uint256 batch;
        while (start < calls.length) {
            uint256 acc;
            uint256 end = start;
            while (end < calls.length && acc + calls[end].gasUsed + PER_CALL_OVERHEAD <= BATCH_GAS_CAP) {
                acc += calls[end].gasUsed + PER_CALL_OVERHEAD;
                end++;
            }
            require(end > start, "single call exceeds the gas cap");

            bytes memory packed;
            for (uint256 i = start; i < end; i++) {
                bytes memory inner =
                    abi.encodeWithSelector(IAvsOperatorManager.adminForwardCall.selector,
                        calls[i].operatorId, calls[i].target, calls[i].selector, calls[i].args);
                packed = abi.encodePacked(
                    packed, uint8(0), ETHERFI_AVS_OPERATORS_MANAGER, uint256(0), inner.length, inner
                );
            }

            batch++;
            console2.log("--- batch", batch);
            console2.log("calls:   ", end - start);
            console2.log("est gas: ", acc);
            console2.log("multiSend(bytes) calldata:");
            console2.logBytes(abi.encodeWithSignature("multiSend(bytes)", packed));
            console2.log("");

            start = end;
        }
        console2.log("total Safe txs:", batch);
    }
}
