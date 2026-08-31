// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "forge-std/Script.sol";
import "forge-std/console2.sol";
import {Deployed} from "@scripts/deploys/Deployed.s.sol";

interface ISafe {
    function nonce() external view returns (uint256);
    function getOwners() external view returns (address[] memory);
    function getThreshold() external view returns (uint256);
    function approveHash(bytes32 hashToApprove) external;
    function getTransactionHash(
        address to,
        uint256 value,
        bytes calldata data,
        uint8 operation,
        uint256 safeTxGas,
        uint256 baseGas,
        uint256 gasPrice,
        address gasToken,
        address refundReceiver,
        uint256 _nonce
    ) external view returns (bytes32);
    function execTransaction(
        address to,
        uint256 value,
        bytes calldata data,
        uint8 operation,
        uint256 safeTxGas,
        uint256 baseGas,
        uint256 gasPrice,
        address gasToken,
        address payable refundReceiver,
        bytes calldata signatures
    ) external payable returns (bool);
}

interface IAvsOperatorManager {
    function adminForwardCall(uint256 id, address target, bytes4 selector, bytes calldata args) external;
    function avsOperators(uint256 id) external view returns (address);
}

interface IAVSDirectory {
    function avsOperatorStatus(address avs, address operator) external view returns (uint8);
}

/**
 * @title VerifyAvsBatches
 * @notice Executes the AVS deregistration batches as the REAL Safe transactions:
 *         execTransaction -> delegatecall MultiSendCallOnly -> N x adminForwardCall.
 *
 * Signatures are supplied through Safe's approved-hash type (v = 1), which needs no private key:
 * threshold is forced to 1 via vm.store, then one owner calls approveHash.
 *
 * command:
 * forge script script/upgrades/avs-deregistration/VerifyAvsBatches.s.sol:VerifyAvsBatches \
 *   --fork-url $MAINNET_RPC_URL -vvv
 */
contract VerifyAvsBatches is Script, Deployed {
    ISafe constant safe = ISafe(ETHERFI_OPERATING_ADMIN);
    address constant MULTISEND_CALL_ONLY = 0x40A2aCCbd92BCA938b02010E17A5b8929b49130D;
    IAVSDirectory constant avsDirectory = IAVSDirectory(0x135DDa560e946695d6f155dACaFC6f1F25C1F5AF);

    uint256 constant BATCH_GAS_CAP = 12_000_000;
    uint256 constant PER_CALL_OVERHEAD = 30_000;
    /// @dev Safe 1.3.0 storage: slot 4 holds the threshold
    uint256 constant SAFE_THRESHOLD_SLOT = 4;

    struct Call {
        uint256 operatorId;
        address avs;
        address target;
        bytes4 selector;
        bytes args;
        uint256 gasUsed;
    }

    Call[] internal calls;

    function run() public {
        _loadCalls();

        address owner = safe.getOwners()[0];
        vm.store(address(safe), bytes32(SAFE_THRESHOLD_SLOT), bytes32(uint256(1)));
        require(safe.getThreshold() == 1, "threshold override failed");
        vm.deal(owner, owner.balance + 100 ether);
        console2.log("owner used for approved-hash signing:", owner);

        uint256 batches;
        uint256 start;
        uint256 maxGas;

        while (start < calls.length) {
            (uint256 end, uint256 est) = _packFrom(start);
            bytes memory multiSendData = _buildMultiSend(start, end);

            uint256 n = safe.nonce();
            bytes32 txHash = safe.getTransactionHash(
                MULTISEND_CALL_ONLY, 0, multiSendData, 1, 0, 0, 0, address(0), address(0), n
            );

            vm.prank(owner);
            safe.approveHash(txHash);

            // approved-hash signature: r = owner, s = 0, v = 1
            bytes memory sig = abi.encodePacked(bytes32(uint256(uint160(owner))), bytes32(0), uint8(1));

            uint256 before = gasleft();
            vm.prank(owner);
            bool ok = safe.execTransaction(
                MULTISEND_CALL_ONLY, 0, multiSendData, 1, 0, 0, 0, address(0), payable(address(0)), sig
            );
            uint256 spent = before - gasleft();
            require(ok, "execTransaction returned false");

            batches++;
            if (spent > maxGas) maxGas = spent;
            console2.log("--- batch", batches);
            console2.log("nonce:      ", n);
            console2.log("inner calls:", end - start);
            console2.log("est gas:    ", est);
            console2.log("exec gas:   ", spent);

            start = end;
        }

        console2.log("");
        console2.log("batches executed:", batches);
        console2.log("max exec gas:    ", maxGas);
        require(maxGas < BATCH_GAS_CAP, "a batch exceeded the 12M ceiling");

        _verifyAllDeregistered();
    }

    function _packFrom(uint256 start) internal view returns (uint256 end, uint256 acc) {
        end = start;
        while (end < calls.length && acc + calls[end].gasUsed + PER_CALL_OVERHEAD <= BATCH_GAS_CAP) {
            acc += calls[end].gasUsed + PER_CALL_OVERHEAD;
            end++;
        }
        require(end > start, "single call exceeds the cap");
    }

    function _buildMultiSend(uint256 start, uint256 end) internal view returns (bytes memory) {
        bytes memory packed;
        for (uint256 i = start; i < end; i++) {
            bytes memory inner = abi.encodeWithSelector(
                IAvsOperatorManager.adminForwardCall.selector,
                calls[i].operatorId, calls[i].target, calls[i].selector, calls[i].args
            );
            packed = abi.encodePacked(
                packed, uint8(0), ETHERFI_AVS_OPERATORS_MANAGER, uint256(0), inner.length, inner
            );
        }
        return abi.encodeWithSignature("multiSend(bytes)", packed);
    }

    function _verifyAllDeregistered() internal view {
        uint256 still;
        for (uint256 i = 0; i < calls.length; i++) {
            address operator = IAvsOperatorManager(ETHERFI_AVS_OPERATORS_MANAGER).avsOperators(calls[i].operatorId);
            if (avsDirectory.avsOperatorStatus(calls[i].avs, operator) != 0) {
                console2.log("[STILL REGISTERED] operator", calls[i].operatorId, calls[i].avs);
                still++;
            }
        }
        require(still == 0, "some pairs are still registered");
        console2.log("[OK] all pairs read UNREGISTERED after the real Safe txs");
    }

    function _loadCalls() internal {
        string memory json = vm.readFile("script/upgrades/avs-deregistration/avs-deregistration-calls.json");
        for (uint256 i = 0; ; i++) {
            string memory p = string.concat(".calls[", vm.toString(i), "]");
            if (!vm.keyExistsJson(json, p)) break;
            calls.push(
                Call({
                    operatorId: vm.parseJsonUint(json, string.concat(p, ".operatorId")),
                    avs: vm.parseJsonAddress(json, string.concat(p, ".avs")),
                    target: vm.parseJsonAddress(json, string.concat(p, ".target")),
                    selector: bytes4(vm.parseJsonBytes(json, string.concat(p, ".selector"))),
                    args: vm.parseJsonBytes(json, string.concat(p, ".args")),
                    gasUsed: vm.parseJsonUint(json, string.concat(p, ".gasUsed"))
                })
            );
        }
        console2.log("loaded calls:", calls.length);
    }
}
