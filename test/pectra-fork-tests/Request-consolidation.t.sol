// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import "../../src/EtherFiNodesManager.sol";
import "../../src/EtherFiNode.sol";
import "../../src/EtherFiTimelock.sol";
import "../../src/RoleRegistry.sol";
import "../../src/interfaces/IRoleRegistry.sol";
import {IEigenPod, IEigenPodTypes } from "../../src/eigenlayer-interfaces/IEigenPod.sol";

/**
 * @title RequestConsolidationTest
 * @notice test for request consolidation
 * @dev Run with: forge test --fork-url <mainnet-rpc> --match-path test/pectra-fork-tests/Request-consolidation.t.sol -vvvv
 */

contract RequestConsolidationTest is Test {
    // === MAINNET CONTRACT ADDRESSES ===
    EtherFiNodesManager constant etherFiNodesManager = EtherFiNodesManager(payable(0x8B71140AD2e5d1E7018d2a7f8a288BD3CD38916F));
    RoleRegistry constant roleRegistry = RoleRegistry(0x62247D29B4B9BECf4BB73E0c722cf6445cfC7cE9);

    EtherFiTimelock constant etherFiOperatingTimelock = EtherFiTimelock(payable(0xcD425f44758a08BaAB3C4908f3e3dE5776e45d7a));
    address constant realElExiter = 0x12582A27E5e19492b4FcD194a60F8f5e1aa31B0F;

    // Consolidate the following validators:
    bytes constant PK_54120 = hex"84308db55e1688dc019ad18228220a4b40c9014615e830eb8e68510e43792c25eed145c65017dca7c77b01c24e1fe9ca";
    bytes constant PK_54121 = hex"82febf0b87334dca3b798dac8838a99eed9e91533c4f6cbc19a7fabdbca15bb7d38f0c58dc4c79e6a88a39cf98330db7";

    function setUp() public {}

    function _resolvePod(bytes memory pubkey) internal view returns (IEtherFiNode etherFiNode, IEigenPod pod) {
        bytes32 pkHash = etherFiNodesManager.calculateValidatorPubkeyHash(pubkey);
        etherFiNode = etherFiNodesManager.etherFiNodeFromPubkeyHash(pkHash);
        pod = etherFiNode.getEigenPod();
        require(address(pod) != address(0), "test: node has no pod");
    }

    function _requestsFromPubkeys(bytes[] memory pubkeys)
        internal
        pure
        returns (IEigenPodTypes.ConsolidationRequest[] memory reqs) {
        reqs = new IEigenPodTypes.ConsolidationRequest[](pubkeys.length);
        for (uint256 i = 0; i < pubkeys.length; ++i) {
            reqs[i] = IEigenPodTypes.ConsolidationRequest({
                srcPubkey: pubkeys[i],
                targetPubkey: pubkeys[i]
            });
        }
        }

    function test_RequestConsolidation() public {
        console2.log("=== REQUEST CONSOLIDATION TEST ===");
        bool hasRole = roleRegistry.hasRole(etherFiNodesManager.ETHERFI_NODES_MANAGER_EL_TRIGGER_EXIT_ROLE(), realElExiter);
        require(hasRole, "test: realElExiter does not have the EL Trigger Exit Role");

        bytes[] memory pubkeys = new bytes[](2);
        uint256[] memory legacyIds = new uint256[](2);
        pubkeys[0] = PK_54120;
        pubkeys[1] = PK_54121;
        legacyIds[0] = 54120;
        legacyIds[1] = 54121;

        vm.prank(address(etherFiOperatingTimelock));
        etherFiNodesManager.linkLegacyValidatorIds(legacyIds, pubkeys); 
        vm.stopPrank();  

        ( , IEigenPod pod0) = _resolvePod(pubkeys[0]);
        ( , IEigenPod pod1) = _resolvePod(pubkeys[1]);
        assertEq(address(pod0), address(pod1));

        IEigenPodTypes.ConsolidationRequest[] memory reqs = _requestsFromPubkeys(pubkeys);

        uint256 feePer = pod0.getConsolidationRequestFee();
        uint256 n = reqs.length;
        uint256 valueToSend = feePer * n;

        vm.expectEmit(true, true, true, true, address(etherFiNodesManager));
        emit IEtherFiNodesManager.ValidatorConsolidationRequested(
            address(pod0),
            etherFiNodesManager.calculateValidatorPubkeyHash(pubkeys[0]),
            pubkeys[0],
            etherFiNodesManager.calculateValidatorPubkeyHash(pubkeys[1]),
            pubkeys[1]
        );
        vm.prank(address(etherFiOperatingTimelock));
        etherFiNodesManager.requestConsolidation{value: valueToSend}(reqs);

    }
}