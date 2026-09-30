// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "@tests/behaviour-tests/prelude.t.sol";
import {IEtherFiNode} from "@etherfi/staking/interfaces/IEtherFiNode.sol";
import {IEigenPodManager} from "@etherfi/interfaces/eigenlayer-interfaces/IEigenPodManager.sol";

/// @notice A node's pod-or-no-pod status is treated as immutable by the credential resolver. This
///         pins that even a whitelisted forwarding entry cannot make a node create a pod on the
///         EigenPodManager, which would attach a pod to a funded pod-less node and silently flip its
///         withdrawal-credential resolution from node to pod.
contract ForwardingCreatePodDenyTest is PreludeTest {
    function _newPodLessNode() internal returns (address) {
        vm.prank(admin);
        return stakingManager.instantiateEtherFiNode(/*createEigenPod=*/ false);
    }

    function _forward(address node, bytes memory data) internal {
        address[] memory nodes = new address[](1);
        nodes[0] = node;
        bytes[] memory payloads = new bytes[](1);
        payloads[0] = data;
        vm.prank(callForwarder); // EIGENPOD_OPERATIONS_ROLE
        etherFiNodesManager.forwardExternalCall(nodes, payloads, eigenPodManager);
    }

    function test_forwardExternalCall_cannotCreatePodOnEigenPodManager() public {
        address node = _newPodLessNode();
        bytes4 sel = IEigenPodManager.createPod.selector;

        // Even with the operating timelock whitelisting createPod on the EigenPodManager...
        vm.prank(admin); // OPERATION_TIMELOCK_ROLE
        etherFiNodesManager.updateAllowedForwardedExternalCalls(callForwarder, sel, eigenPodManager, true);

        vm.expectRevert(IEtherFiNode.ForwardedCallNotAllowed.selector);
        _forward(node, abi.encodeWithSelector(sel));
    }

    function test_forwardExternalCall_cannotStakeOnEigenPodManager() public {
        address node = _newPodLessNode();
        bytes4 sel = IEigenPodManager.stake.selector;

        vm.prank(admin);
        etherFiNodesManager.updateAllowedForwardedExternalCalls(callForwarder, sel, eigenPodManager, true);

        vm.expectRevert(IEtherFiNode.ForwardedCallNotAllowed.selector);
        _forward(node, abi.encodeWithSelector(sel, bytes(""), bytes(""), bytes32(0)));
    }
}
