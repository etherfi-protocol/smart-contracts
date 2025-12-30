// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "forge-std/Script.sol";
import "forge-std/console2.sol";
import "forge-std/StdJson.sol";

import {IDelegationManager} from "../../../src/eigenlayer-interfaces/IDelegationManager.sol";

import "../../utils/utils.sol";

/**
 * @notice Prints EigenLayer operator addresses for every node in `etherFiNodes.json`.
 *
 * Operator is fetched from EigenLayer `DelegationManager.delegatedTo(node)`.
 * Also prints a separate array of nodes whose operator == `_A41_OPERATOR_MANAGER`.
 *
 * Command (mainnet fork dry-run):
 * forge script script/operator-management/printA41OperatorAddresses.s.sol:PrintA41OperatorAddresses \
 *   --fork-url $MAINNET_RPC_URL -vvvv
 *
 * Optional env:
 * - INPUT_JSON: path to JSON file (default: `<repo>/script/operator-management/etherFiNodes.json`)
 */
contract PrintA41OperatorAddresses is Script, Utils {
    using stdJson for string;

    address internal constant _MAINNET_EIGENLAYER_DELEGATION_MANAGER = 0x39053D51B77DC0d36036Fc1fCc8Cb819df8Ef37A;
    address internal constant _A41_OPERATOR_MANAGER = 0xe0156eF2905c2Ea8B1F7571cAEE85fdF1657Ab38;

    function run() external {
        IDelegationManager delegationManager = IDelegationManager(_MAINNET_EIGENLAYER_DELEGATION_MANAGER);

        string memory jsonPath = vm.envOr("INPUT_JSON", _defaultInputPath());
        string memory jsonData = vm.readFile(jsonPath);

        uint256 nodeCount = _countNodeEntries(jsonData);
        address[] memory nodes = new address[](nodeCount);
        address[] memory operators = new address[](nodeCount);
        address[] memory a41OperatorNodesTmp = new address[](nodeCount);

        console2.log("=== A41 NODE -> OPERATOR (EIGENLAYER) ===");
        console2.log("DelegationManager:", _MAINNET_EIGENLAYER_DELEGATION_MANAGER);
        console2.log("Input:", jsonPath);
        console2.log("Entries:", nodeCount);
        console2.log("");

        uint256 a41OperatorCount = 0;
        for (uint256 i = 0; i < nodeCount; i++) {
            address node = stdJson.readAddress(jsonData, string.concat("$[", vm.toString(i), "].node_address"));
            address operator = delegationManager.delegatedTo(node);

            nodes[i] = node;
            if (operator == _A41_OPERATOR_MANAGER) {
                a41OperatorNodesTmp[a41OperatorCount] = node;
                unchecked {
                    ++a41OperatorCount;
                }
            }

            operators[i] = operator;

            console2.log("idx:", i);
            console2.log("  node:", node);
            console2.log("  operator:", operator);
        }

        console2.log("");
        console2.log("=== Operators array ===");
        console2.log(formatAddressArray(operators));

        console2.log("");
        console2.log("=== Nodes array ===");
        console2.log(formatAddressArray(nodes));

        address[] memory a41OperatorNodes = new address[](a41OperatorCount);
        for (uint256 i = 0; i < a41OperatorCount; i++) {
            a41OperatorNodes[i] = a41OperatorNodesTmp[i];
        }

        console2.log("");
        console2.log("=== A41 Operator Nodes array ===");
        console2.log(formatAddressArray(a41OperatorNodes));
    }

    function _defaultInputPath() internal view returns (string memory) {
        return string.concat(vm.projectRoot(), "/script/operator-management/etherFiNodes.json");
    }

    function _countNodeEntries(string memory jsonData) internal view returns (uint256 n) {
        while (true) {
            string memory path = string.concat("$[", vm.toString(n), "].node_address");
            if (!stdJson.keyExists(jsonData, path)) break;
            unchecked {
                ++n;
            }
        }
        if (n == 0) revert("INPUT_JSON: empty node_address array");
    }
}
