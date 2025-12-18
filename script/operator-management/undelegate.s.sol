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
 *      avoiding per-staker private keys.
 * @dev This script is designed for the Operating Timelock:
 *      it prints the calldata for `EtherFiTimelock.scheduleBatch(...)` and `EtherFiTimelock.executeBatch(...)`
 *      targeting `EtherFiNodesManager.forwardExternalCall(...)`.
 *
 * Input JSON (env `INPUT_JSON`, default: `<repo>/script/operator-management/a41-node-address.json`)
 * - Expected: [ { "node_address": "0x..." }, ... ]
 *
 * Env (optional):
 * - NODES_MANAGER: EtherFiNodesManager address (default mainnet)
 * - DELEGATION_MANAGER: EigenLayer DelegationManager address (default mainnet)
 * - OPERATING_TIMELOCK: EtherFi Operating Timelock address (default mainnet)
 */
contract UndelegateAllStakers is Script, Utils {
    using stdJson for string;

    address internal constant _MAINNET_EIGENLAYER_DELEGATION_MANAGER = 0x39053D51B77DC0d36036Fc1fCc8Cb819df8Ef37A;

    bytes4 internal constant _UNDELEGATE_SELECTOR = IDelegationManager.undelegate.selector;

    EtherFiNodesManager internal _nodesManager;
    IDelegationManager internal _delegationManager;
    EtherFiTimelock internal _operatingTimelock;
    RoleRegistry internal _roleRegistry;
    address internal _nodesManagerAddr;
    address internal _delegationManagerAddr;
    address internal _operatingTimelockAddr;

    function run() external {
        _initAddresses();

        string memory jsonPath = vm.envOr("INPUT_JSON", _defaultInputPath());
        address[] memory nodesAll = _loadNodesFromNodeAddressArray(vm.readFile(jsonPath));

        console2.log("=== UNDELEGATE (OPERATING TIMELOCK) ===");
        console2.log("NodesManager:", _nodesManagerAddr);
        console2.log("DelegationManager:", _delegationManagerAddr);
        console2.log("OperatingTimelock:", _operatingTimelockAddr);
        console2.log("Input:", jsonPath);
        console2.log("Nodes in input:", nodesAll.length);
        console2.log("");

        _validateTimelockCanForward();

        // Filter nodes to only those currently delegated (avoid guaranteed revert).
        (address[] memory nodes, bytes[] memory batchData, uint256 skipped) = _buildUndelegateBatch(nodesAll, _delegationManager);
        console2.log("Skipped (not delegated / operator / zero):", skipped);
        console2.log("Attempting undelegate for nodes:", nodes.length);
        console2.log("");
        if (nodes.length == 0) revert("NO_NODES_TO_UNDELEGATE");

        _printTimelockScheduleExecute(nodes, batchData);
    }

    function _initAddresses() internal {
        _nodesManagerAddr = vm.envOr("NODES_MANAGER", ETHERFI_NODES_MANAGER);
        _delegationManagerAddr = vm.envOr("DELEGATION_MANAGER", _MAINNET_EIGENLAYER_DELEGATION_MANAGER);
        _operatingTimelockAddr = vm.envOr("OPERATING_TIMELOCK", OPERATING_TIMELOCK);

        _nodesManager = EtherFiNodesManager(payable(_nodesManagerAddr));
        _delegationManager = IDelegationManager(_delegationManagerAddr);
        _operatingTimelock = EtherFiTimelock(payable(_operatingTimelockAddr));
        _roleRegistry = RoleRegistry(address(_nodesManager.roleRegistry()));
    }

    function _validateTimelockCanForward() internal view {
        bytes32 forwarderRole = _nodesManager.ETHERFI_NODES_MANAGER_CALL_FORWARDER_ROLE();
        if (!_roleRegistry.hasRole(forwarderRole, _operatingTimelockAddr)) revert("OPERATING_TIMELOCK_MISSING_CALL_FORWARDER_ROLE");

        if (!_nodesManager.allowedForwardedExternalCalls(_operatingTimelockAddr, _UNDELEGATE_SELECTOR, _delegationManagerAddr)) {
            revert("OPERATING_TIMELOCK_NOT_WHITELISTED_FOR_UNDELEGATE");
        }
    }

    function _printTimelockScheduleExecute(address[] memory nodes, bytes[] memory batchData) internal view {
        bytes memory forwardExternalCallData = abi.encodeWithSelector(
            _nodesManager.forwardExternalCall.selector,
            nodes,
            batchData,
            _delegationManagerAddr
        );

        address[] memory targets = new address[](1);
        targets[0] = _nodesManagerAddr;
        uint256[] memory values = new uint256[](1);
        values[0] = 0;
        bytes[] memory payloads = new bytes[](1);
        payloads[0] = forwardExternalCallData;

        bytes32 predecessor = bytes32(0);
        bytes32 timelockSalt = keccak256(abi.encode(targets, payloads, block.number));

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
        console2.log("timelockSalt:");
        console2.logBytes32(timelockSalt);
        console2.log("calldata:");
        console2.logBytes(scheduleCalldata);
        console2.log("====================================================");
        console2.log("");

        console2.log("=== Execute undelegate batch (Operating Timelock) ===");
        console2.log("timelockSalt:");
        console2.logBytes32(timelockSalt);
        console2.log("calldata:");
        console2.logBytes(executeCalldata);
        console2.log("===================================================");
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

    function _buildUndelegateBatch(
        address[] memory nodesAll,
        IDelegationManager delegationManager
    )
        internal
        view
        returns (address[] memory nodes, bytes[] memory data, uint256 skipped)
    {
        uint256 n = nodesAll.length;
        nodes = new address[](n);
        data = new bytes[](n);

        uint256 k = 0;
        for (uint256 i = 0; i < n; i++) {
            address node = nodesAll[i];

            if (node == address(0)) {
                skipped++;
                continue;
            }
            if (!delegationManager.isDelegated(node)) {
                skipped++;
                continue;
            }
            // DelegationManager.undelegate(staker) reverts if staker is also an operator.
            if (delegationManager.isOperator(node)) {
                skipped++;
                continue;
            }

            nodes[k] = node;
            data[k] = abi.encodeWithSelector(_UNDELEGATE_SELECTOR, node);
            unchecked {
                ++k;
            }
        }

        assembly {
            mstore(nodes, k)
            mstore(data, k)
        }
    }
}

