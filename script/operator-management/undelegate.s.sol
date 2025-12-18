// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "forge-std/console2.sol";
import "forge-std/StdJson.sol";
import "forge-std/Script.sol";

import "../utils/utils.sol";

import {EtherFiTimelock} from "../../src/EtherFiTimelock.sol";
import {EtherFiNodesManager} from "../../src/EtherFiNodesManager.sol";
import {RoleRegistry} from "../../src/RoleRegistry.sol";
import {IDelegationManager} from "../../src/eigenlayer-interfaces/IDelegationManager.sol";

/**
 * @title UndelegateAllStakers
 * @notice Calls EigenLayer `DelegationManager.undelegate(staker)` for a list of EtherFi node "stakers".
 * @dev Uses `EtherFiNodesManager.forwardExternalCall()` so the EtherFiNode is the caller (i.e. the staker),
 * @dev This script is designed for the Operating Timelock:
 *      it prints the calldata for `EtherFiTimelock.scheduleBatch(...)` and `EtherFiTimelock.executeBatch(...)`
 *      which will:
 *        a) whitelist forwarded `delegateTo` on EigenLayer DelegationManager for Operating Timelock
 *        b) whitelist forwarded `redelegate` on EigenLayer DelegationManager for Operating Timelock
 *        c) whitelist forwarded `undelegate` on EigenLayer DelegationManager for Operating Timelock
 *        d) forward batched `undelegate` calls for all A41 nodes
 *
 * Input JSON (env `INPUT_JSON`, default: `<repo>/script/operator-management/a41-node-address.json`)
 * - Expected: [ { "node_address": "0x..." }, ... ]

 COMMAND:
 forge script script/operator-management/undelegate.s.sol:UndelegateAllStakers \
     --fork-url $MAINNET_RPC_URL \
     -- --fs script/operator-management \
     -vvvv
 */
contract UndelegateAllStakers is Script, Utils {
    using stdJson for string;

    address internal constant _MAINNET_EIGENLAYER_DELEGATION_MANAGER = 0x39053D51B77DC0d36036Fc1fCc8Cb819df8Ef37A;

    // EigenLayer DelegationManager selectors we must whitelist for the Operating Timelock.
    bytes4 internal constant _DELEGATE_TO_SELECTOR = IDelegationManager.delegateTo.selector;
    bytes4 internal constant _REDELEGATE_SELECTOR = IDelegationManager.redelegate.selector;
    bytes4 internal constant _UNDELEGATE_SELECTOR = IDelegationManager.undelegate.selector;

    EtherFiTimelock internal _operatingTimelock;
    IDelegationManager internal _delegationManager;
    EtherFiNodesManager internal _nodesManager;
    RoleRegistry internal _roleRegistry;

    function run() external {
        _initAddresses();

        string memory jsonPath = vm.envOr("INPUT_JSON", _defaultInputPath());
        address[] memory nodesAll = _loadNodesFromNodeAddressArray(vm.readFile(jsonPath));

        console2.log("=== A41 UNDELEGATION VIA ETHERFI NODES MANAGER (EIGENLAYER) ===");
        console2.log("OperatingSafe (expected):", ETHERFI_OPERATING_ADMIN);
        console2.log("Safe nonce (schedule, expected):", uint256(644));
        console2.log("Safe nonce (execute, expected):", uint256(645));
        console2.log("NodesManager:", ETHERFI_NODES_MANAGER);
        console2.log("DelegationManager:", _MAINNET_EIGENLAYER_DELEGATION_MANAGER);
        console2.log("OperatingTimelock:", OPERATING_TIMELOCK);
        console2.log("Input:", jsonPath);
        console2.log("Nodes in input:", nodesAll.length);
        console2.log("");

        // We intentionally build the undelegate batch for ALL nodes (no skipping) to match ops.
        // Pre-validate on-chain state to avoid a guaranteed revert on execute.
        _validateNodesUndelegatable(nodesAll, _delegationManager);
        (address[] memory nodes, bytes[] memory batchData) = _buildUndelegateBatchAll(nodesAll);

        // vm.startBroadcast(ETHERFI_OPERATING_ADMIN);
        vm.startPrank(ETHERFI_OPERATING_ADMIN);
        _timelockTx(nodes, batchData);
        _checkUpdatedState(nodes);
    }

    function _initAddresses() internal {
        _nodesManager = EtherFiNodesManager(payable(ETHERFI_NODES_MANAGER));
        _delegationManager = IDelegationManager(_MAINNET_EIGENLAYER_DELEGATION_MANAGER);
        _operatingTimelock = EtherFiTimelock(payable(OPERATING_TIMELOCK));
        _roleRegistry = RoleRegistry(ROLE_REGISTRY);
    }

    function _timelockTx(address[] memory nodes, bytes[] memory batchData) internal {
        // a) Whitelist forwarded delegateTo on DelegationManager for Operating Timelock
        // b) Whitelist forwarded redelegate on DelegationManager for Operating Timelock
        // c) Whitelist forwarded undelegate on DelegationManager for Operating Timelock
        // d) Forward batched undelegate calls for the 26 A41 nodes
        bytes[] memory payloads = new bytes[](4);
        payloads[0] = abi.encodeWithSelector(
            _nodesManager.updateAllowedForwardedExternalCalls.selector,
            OPERATING_TIMELOCK,
            _DELEGATE_TO_SELECTOR,
            _MAINNET_EIGENLAYER_DELEGATION_MANAGER,
            true
        );
        payloads[1] = abi.encodeWithSelector(
            _nodesManager.updateAllowedForwardedExternalCalls.selector,
            OPERATING_TIMELOCK,
            _REDELEGATE_SELECTOR,
            _MAINNET_EIGENLAYER_DELEGATION_MANAGER,
            true
        );
        payloads[2] = abi.encodeWithSelector(
            _nodesManager.updateAllowedForwardedExternalCalls.selector,
            OPERATING_TIMELOCK,
            _UNDELEGATE_SELECTOR,
            _MAINNET_EIGENLAYER_DELEGATION_MANAGER,
            true
        );

        bytes memory forwardExternalCallData = abi.encodeWithSelector(
            _nodesManager.forwardExternalCall.selector,
            nodes,
            batchData,
            _MAINNET_EIGENLAYER_DELEGATION_MANAGER
        );
        payloads[3] = forwardExternalCallData;

        address[] memory targets = new address[](payloads.length);
        uint256[] memory values = new uint256[](payloads.length);
        for (uint256 i = 0; i < payloads.length; i++) {
            targets[i] = ETHERFI_NODES_MANAGER;
            values[i] = 0;
        }

        bytes32 predecessor = bytes32(0);
        bytes32 timelockSalt = keccak256(abi.encode("A41_UNDELEGATION_EIGENLAYER", ETHERFI_NODES_MANAGER, _MAINNET_EIGENLAYER_DELEGATION_MANAGER, nodes));

        bytes memory scheduleCalldata = abi.encodeWithSelector(
            _operatingTimelock.scheduleBatch.selector,
            targets,
            values,
            payloads,
            predecessor,
            timelockSalt,
            MIN_DELAY_OPERATING_TIMELOCK
        );

        bytes memory executeCalldata = abi.encodeWithSelector(
            _operatingTimelock.executeBatch.selector,
            targets,
            values,
            payloads,
            predecessor,
            timelockSalt
        );

        console2.log("=== Schedule undelegate batch (Operating Timelock) ===");
        console2.log("calldata:");
        console2.logBytes(scheduleCalldata);
        console2.log("====================================================");
        console2.log("");


        console2.log("=== Execute undelegate batch (Operating Timelock) ===");
        console2.log("calldata:");
        console2.logBytes(executeCalldata);
        console2.log("===================================================");

        _operatingTimelock.scheduleBatch(targets, values, payloads, predecessor, timelockSalt, MIN_DELAY_OPERATING_TIMELOCK);

        vm.warp(block.timestamp + MIN_DELAY_OPERATING_TIMELOCK + 1);

        _operatingTimelock.executeBatch(targets, values, payloads, predecessor, timelockSalt);

        console2.log("=== Undelegate batch executed successfully ===");
        console2.log("===================================================");
        console2.log("");
    }

    function _checkUpdatedState(address[] memory nodes) internal {
        // check whitelisted forwarded external calls
        console2.log("=== Check whitelisted forwarded external calls ===");
        console2.log("delegateTo:", _nodesManager.allowedForwardedExternalCalls(OPERATING_TIMELOCK, _DELEGATE_TO_SELECTOR, _MAINNET_EIGENLAYER_DELEGATION_MANAGER));
        console2.log("redelegate:", _nodesManager.allowedForwardedExternalCalls(OPERATING_TIMELOCK, _REDELEGATE_SELECTOR, _MAINNET_EIGENLAYER_DELEGATION_MANAGER));
        console2.log("undelegate:", _nodesManager.allowedForwardedExternalCalls(OPERATING_TIMELOCK, _UNDELEGATE_SELECTOR, _MAINNET_EIGENLAYER_DELEGATION_MANAGER));
        console2.log("===================================================");

        // check if nodes are undelegated
        for (uint256 i = 0; i < nodes.length; i++) {
            if (_delegationManager.isDelegated(nodes[i])) {
                revert(string.concat("POSTCHECK: node is still delegated at index=", vm.toString(i)));
            }
        }
        console2.log("All nodes are undelegated");
    }

    function _defaultInputPath() internal view returns (string memory) {
        return string.concat(vm.projectRoot(), "/script/operator-management/a41-node-address.json");
    }

    function _loadNodesFromNodeAddressArray(string memory jsonData) internal view returns (address[] memory nodes) {
        // Count array length by probing for sequential indices.
        uint256 n = 0;
        while (true) {
            string memory path = string.concat("$[", vm.toString(n), "].node_address");
            if (!stdJson.keyExists(jsonData, path)) break;
            unchecked {
                ++n;
            }
        }
        if (n == 0) revert("INPUT_JSON: empty node_address array");

        nodes = new address[](n);
        for (uint256 i = 0; i < n; i++) {
            nodes[i] = stdJson.readAddress(jsonData, string.concat("$[", vm.toString(i), "].node_address"));
        }
    }

    function _validateNodesUndelegatable(address[] memory nodesAll, IDelegationManager delegationManager) internal view {
        for (uint256 i = 0; i < nodesAll.length; i++) {
            address node = nodesAll[i];
            if (node == address(0)) revert(string.concat("INPUT_JSON: node_address is zero at index=", vm.toString(i)));
            if (!delegationManager.isDelegated(node)) {
                revert(string.concat("PRECHECK: node not delegated at index=", vm.toString(i)));
            }
            // DelegationManager.undelegate(staker) reverts if staker is also an operator.
            if (delegationManager.isOperator(node)) {
                revert(string.concat("PRECHECK: node is operator (cannot undelegate) at index=", vm.toString(i)));
            }
        }
    }

    function _buildUndelegateBatchAll(address[] memory nodesAll) internal pure returns (address[] memory nodes, bytes[] memory data) {
        uint256 n = nodesAll.length;
        nodes = new address[](n);
        data = new bytes[](n);
        for (uint256 i = 0; i < n; i++) {
            address node = nodesAll[i];
            nodes[i] = node;
            data[i] = abi.encodeWithSelector(_UNDELEGATE_SELECTOR, node);
        }
    }
}
