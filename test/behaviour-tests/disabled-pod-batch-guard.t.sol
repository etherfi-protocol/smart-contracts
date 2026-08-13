// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "@tests/behaviour-tests/prelude.t.sol";
import {IEigenPod, IEigenPodTypes} from "@etherfi/interfaces/eigenlayer-interfaces/IEigenPod.sol";
import {EigenPodTestHelpers} from "@tests/utils/EigenPodTestHelpers.sol";

/// @notice Verifies the disabled-pod batch-membership guard in EtherFiNodesManager.
/// @dev Once a pod is disabled (EL v1.14), EigenLayer stops enforcing pod membership, so the manager
///      must verify each batch source belongs to the pod's OWN validator set (validatorStatus), not
///      etherFiNodeFromPubkeyHash. The earlier map-based attempt wrongly rejected legitimate same-pod
///      sources that were never linked into the map; this test pins that difference:
///        - a source ACTIVE in the pod but NOT in the map must PASS,
///        - a source not in the pod (INACTIVE) must REVERT MixedNodeRequest.
contract DisabledPodBatchGuardTest is PreludeTest {
    // Real mainnet validator used only as the batch anchor (requests[0]) to resolve the node/pod.
    uint256 constant ANCHOR_ID = 80143;
    bytes constant ANCHOR_PK = hex"811cd0bb7dd301afbbddd1d5db15ff0ca9d5f8ada78c0b1223f75b524aca1ca9ff1ba205d9efd7c37c2174576cc123e2";

    // Synthetic 48-byte pubkeys (definitely NOT in etherFiNodeFromPubkeyHash).
    bytes memberPk;      // forced ACTIVE in the pod -> same-pod, unlinked
    bytes foreignPk;     // never forced -> INACTIVE in the pod

    IEtherFiNode node0;
    IEigenPod pod0;

    function _setup() internal {
        memberPk = abi.encodePacked(bytes32(keccak256("member")), bytes16(keccak256("member2")));
        foreignPk = abi.encodePacked(bytes32(keccak256("foreign")), bytes16(keccak256("foreign2")));

        // Resolve the anchor's node/pod, linking the pubkey if mainnet hasn't already.
        bytes32 anchorHash = etherFiNodesManager.calculateValidatorPubkeyHash(ANCHOR_PK);
        if (address(etherFiNodesManager.etherFiNodeFromPubkeyHash(anchorHash)) == address(0)) {
            uint256[] memory ids = new uint256[](1);
            ids[0] = ANCHOR_ID;
            bytes[] memory pks = new bytes[](1);
            pks[0] = ANCHOR_PK;
            vm.prank(admin); // EXECUTOR_OPERATIONS_ROLE
            etherFiNodesManager.linkLegacyValidatorIds(ids, pks);
        }
        node0 = etherFiNodesManager.etherFiNodeFromPubkeyHash(anchorHash);
        require(address(node0) != address(0), "anchor did not resolve to a node");
        pod0 = node0.getEigenPod();
        require(address(pod0) != address(0), "anchor node has no pod");

        // Make the pod look retired (fork pods are pre-v1.14 and have no restakingDisabled state).
        vm.mockCall(address(pod0), abi.encodeWithSignature("restakingDisabled()"), abi.encode(true));

        // memberPk is a validator of THIS pod; foreignPk is left INACTIVE (0) in it.
        EigenPodTestHelpers.forceValidatorActive(pod0, memberPk);
        assertEq(uint256(pod0.validatorStatus(etherFiNodesManager.calculateValidatorPubkeyHash(memberPk))), uint256(IEigenPodTypes.VALIDATOR_STATUS.ACTIVE), "memberPk active in pod");
        assertEq(uint256(pod0.validatorStatus(etherFiNodesManager.calculateValidatorPubkeyHash(foreignPk))), uint256(IEigenPodTypes.VALIDATOR_STATUS.INACTIVE), "foreignPk inactive in pod");
    }

    function _consolidationBatch(bytes memory secondSrc) internal view returns (IEigenPodTypes.ConsolidationRequest[] memory reqs) {
        reqs = new IEigenPodTypes.ConsolidationRequest[](2);
        reqs[0] = IEigenPodTypes.ConsolidationRequest({srcPubkey: ANCHOR_PK, targetPubkey: ANCHOR_PK});
        reqs[1] = IEigenPodTypes.ConsolidationRequest({srcPubkey: secondSrc, targetPubkey: secondSrc});
    }

    function _withdrawalBatch(bytes memory secondPk) internal view returns (IEigenPodTypes.WithdrawalRequest[] memory reqs) {
        reqs = new IEigenPodTypes.WithdrawalRequest[](2);
        reqs[0] = IEigenPodTypes.WithdrawalRequest({pubkey: ANCHOR_PK, amountGwei: 0});
        reqs[1] = IEigenPodTypes.WithdrawalRequest({pubkey: secondPk, amountGwei: 0});
    }

    // --- requestConsolidation ------------------------------------------------------------------

    /// @dev Foreign source (INACTIVE in the pod) must be rejected on a disabled pod.
    function test_consolidation_disabledPod_rejectsForeignSource() public {
        _setup();
        IEigenPodTypes.ConsolidationRequest[] memory reqs = _consolidationBatch(foreignPk);
        uint256 fee = pod0.getConsolidationRequestFee();
        vm.deal(admin, fee * reqs.length + 1 ether);

        vm.expectRevert(IEtherFiNodesManager.MixedNodeRequest.selector);
        vm.prank(admin);
        etherFiNodesManager.requestConsolidation{value: fee * reqs.length}(reqs);
    }

    /// @dev Same-pod source that is ACTIVE but NOT linked in etherFiNodeFromPubkeyHash must pass.
    ///      (The reverted map-based guard would have wrongly reverted MixedNodeRequest here.)
    function test_consolidation_disabledPod_acceptsUnlinkedSamePodSource() public {
        _setup();
        // No-op the downstream pod call so the ENM call returns once the guard passes.
        vm.mockCall(address(node0), abi.encodeWithSelector(IEtherFiNode.requestConsolidation.selector), "");

        IEigenPodTypes.ConsolidationRequest[] memory reqs = _consolidationBatch(memberPk);
        uint256 fee = pod0.getConsolidationRequestFee();
        vm.deal(admin, fee * reqs.length + 1 ether);

        vm.prank(admin);
        etherFiNodesManager.requestConsolidation{value: fee * reqs.length}(reqs); // must NOT revert MixedNodeRequest
    }

    // --- requestExecutionLayerTriggeredWithdrawal ----------------------------------------------

    function test_withdrawal_disabledPod_rejectsForeignSource() public {
        _setup();
        IEigenPodTypes.WithdrawalRequest[] memory reqs = _withdrawalBatch(foreignPk);
        uint256 fee = pod0.getWithdrawalRequestFee();
        vm.deal(admin, fee * reqs.length + 1 ether);

        vm.expectRevert(IEtherFiNodesManager.MixedNodeRequest.selector);
        vm.prank(admin);
        etherFiNodesManager.requestExecutionLayerTriggeredWithdrawal{value: fee * reqs.length}(reqs);
    }

    function test_withdrawal_disabledPod_acceptsUnlinkedSamePodSource() public {
        _setup();
        vm.mockCall(address(node0), abi.encodeWithSelector(IEtherFiNode.requestExecutionLayerTriggeredWithdrawal.selector), "");

        IEigenPodTypes.WithdrawalRequest[] memory reqs = _withdrawalBatch(memberPk);
        uint256 fee = pod0.getWithdrawalRequestFee();
        vm.deal(admin, fee * reqs.length + 1 ether);

        vm.prank(admin);
        etherFiNodesManager.requestExecutionLayerTriggeredWithdrawal{value: fee * reqs.length}(reqs); // must NOT revert MixedNodeRequest
    }

    // --- control: live (non-disabled) pod is not guarded ---------------------------------------

    /// @dev With restaking NOT disabled, the guard branch is skipped entirely (EigenLayer enforces
    ///      membership itself), so a foreign source does not trigger MixedNodeRequest here.
    function test_consolidation_livePod_notGuarded() public {
        _setup();
        vm.clearMockedCalls(); // drop the restakingDisabled()=>true mock; pod reports live again
        vm.mockCall(address(node0), abi.encodeWithSelector(IEtherFiNode.requestConsolidation.selector), "");

        IEigenPodTypes.ConsolidationRequest[] memory reqs = _consolidationBatch(foreignPk);
        uint256 fee = pod0.getConsolidationRequestFee();
        vm.deal(admin, fee * reqs.length + 1 ether);

        vm.prank(admin);
        etherFiNodesManager.requestConsolidation{value: fee * reqs.length}(reqs); // no MixedNodeRequest on a live pod
    }
}
