// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import "../../../src/EtherFiNodesManager.sol";
import "../../../src/EtherFiNode.sol";
import "../../../src/EtherFiTimelock.sol";
import "../../../src/RoleRegistry.sol";
import "../../../src/interfaces/IRoleRegistry.sol";
import {IEigenPod, IEigenPodTypes } from "../../../src/eigenlayer-interfaces/IEigenPod.sol";
import "../../TestSetup.sol";
import "../../../script/deploys/Deployed.s.sol";
/**
 * @title RequestConsolidationTest
 * @notice test for request consolidation
 * @dev Run with: forge test --fork-url <mainnet-rpc> --match-path test/pectra-fork-tests/Request-consolidation.t.sol -vvvv
 */

contract RequestConsolidationTest is TestSetup, Deployed {
    // === MAINNET CONTRACT ADDRESSES ===
    EtherFiNodesManager constant etherFiNodesManager = EtherFiNodesManager(payable(0x8B71140AD2e5d1E7018d2a7f8a288BD3CD38916F));
    RoleRegistry constant roleRegistry = RoleRegistry(0x62247D29B4B9BECf4BB73E0c722cf6445cfC7cE9);

    EtherFiTimelock constant etherFiOperatingTimelock = EtherFiTimelock(payable(0xcD425f44758a08BaAB3C4908f3e3dE5776e45d7a));
    address constant realElExiter = 0x12582A27E5e19492b4FcD194a60F8f5e1aa31B0F;

    bytes constant PK_28689 = hex"88d73705e9c3f29b042d3fe70bdc8781debc5506db43dd00122fd1fa7f4755535d31c7ecb2686ff53669b080ef9e18a3";

    // Consolidate the following validators:
    bytes constant PK_80143 = hex"811cd0bb7dd301afbbddd1d5db15ff0ca9d5f8ada78c0b1223f75b524aca1ca9ff1ba205d9efd7c37c2174576cc123e2";
    bytes constant PK_80194 = hex"b86cb11d564b29a38cdc8a3f1f9c35e6dcd2d0f85f40da60f745e479ba42b4548c83a2b049cf02277fceaa9b421d0039";
    bytes constant PK_89936 = hex"b8786ec7945d737698e374193f05a5498e932e2941263a7842837e9e3fac033af285e53a90afecf994585d178b5eedaa";
    // bytes constant PK_75208 = hex"b87882da67b89b06a59ec23b955ade930b534752153de08a50aa53172ea3439768dce39f547acfee53e55d985d6c4283";

    function setUp() public {
        initializeRealisticFork(MAINNET_FORK);
    }

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

    function _consolidationRequestsFromPubkeys(bytes[] memory pubkeys)
        internal
        pure
        returns (IEigenPodTypes.ConsolidationRequest[] memory reqs) {
        reqs = new IEigenPodTypes.ConsolidationRequest[](pubkeys.length);
        for (uint256 i = 0; i < pubkeys.length; ++i) {
            reqs[i] = IEigenPodTypes.ConsolidationRequest({
                srcPubkey: pubkeys[i],
                targetPubkey: pubkeys[0] // same pod consolidation
            });
        }
    }

    function _switchToCompoundingRequestsFromPubkeys(bytes[] memory pubkeys)
        internal
        pure
        returns (IEigenPodTypes.ConsolidationRequest[] memory reqs) {
        reqs = new IEigenPodTypes.ConsolidationRequest[](pubkeys.length);
        for (uint256 i = 0; i < pubkeys.length; ++i) {
            reqs[i] = IEigenPodTypes.ConsolidationRequest({
                srcPubkey: pubkeys[i],
                targetPubkey: pubkeys[i] // switch to compounding
            }); // same pubkey = switch to compounding
        }
    }

    function test_RequestConsolidation() public {
        console2.log("=== REQUEST CONSOLIDATION TEST ===");
        bool hasRole = roleRegistry.hasRole(etherFiNodesManager.ETHERFI_NODES_MANAGER_EL_CONSOLIDATION_ROLE(), ETHERFI_OPERATING_ADMIN);
        require(hasRole, "test: ETHERFI_OPERATING_ADMIN does not have the Consolidation Role");

        bytes[] memory pubkeys = new bytes[](3);
        pubkeys[0] = PK_80143;
        pubkeys[1] = PK_80194;
        pubkeys[2] = PK_89936;

        uint256[] memory legacyIdsForOneValidator = new uint256[](1);
        legacyIdsForOneValidator[0] = 80143;
        bytes[] memory pubkeysForOneValidator = new bytes[](1);
        pubkeysForOneValidator[0] = PK_80143;
        
        vm.prank(address(etherFiOperatingTimelock));
        etherFiNodesManager.linkLegacyValidatorIds(legacyIdsForOneValidator, pubkeysForOneValidator); 
        vm.stopPrank();
        console.log("Linking legacy validator ids for one validator complete");  

        ( , IEigenPod pod0) = _resolvePod(pubkeys[0]);

        IEigenPodTypes.ConsolidationRequest[] memory reqs = _consolidationRequestsFromPubkeys(pubkeys);

        uint256 feePer = pod0.getConsolidationRequestFee();
        uint256 n = reqs.length;
        uint256 valueToSend = feePer * n;

        // console.log("Fee per request:", feePer);
        // console.log("Number of requests:", n);
        // console.log("Value to send:", valueToSend);

        // Fund the timelock with enough ETH to pay consolidation fees
        vm.deal(address(ETHERFI_OPERATING_ADMIN), valueToSend + 1 ether);

        vm.prank(address(ETHERFI_OPERATING_ADMIN));
        etherFiNodesManager.requestConsolidation{value: valueToSend}(reqs);
    }

    function test_switchToCompounding() public {
        console2.log("=== SWITCH TO COMPOUNDING TEST ===");
        bool hasRole = roleRegistry.hasRole(etherFiNodesManager.ETHERFI_NODES_MANAGER_EL_CONSOLIDATION_ROLE(), ETHERFI_OPERATING_ADMIN);
        require(hasRole, "test: ETHERFI_OPERATING_ADMIN does not have the Consolidation Role");

        bytes[] memory pubkeys = new bytes[](1);
        uint256[] memory legacyIds = new uint256[](1);
        pubkeys[0] = PK_28689;
        legacyIds[0] = 28689;

        vm.prank(address(etherFiOperatingTimelock));
        etherFiNodesManager.linkLegacyValidatorIds(legacyIds, pubkeys); 
        vm.stopPrank();  

        ( , IEigenPod pod0) = _resolvePod(pubkeys[0]);

        IEigenPodTypes.ConsolidationRequest[] memory reqs = _switchToCompoundingRequestsFromPubkeys(pubkeys);

        uint256 feePer = pod0.getConsolidationRequestFee();
        uint256 n = reqs.length;
        uint256 valueToSend = feePer * n;

        // Fund the timelock with enough ETH to pay consolidation fees
        vm.deal(address(ETHERFI_OPERATING_ADMIN), valueToSend + 1 ether);

        vm.expectEmit(true, true, true, true, address(etherFiNodesManager));
        emit IEtherFiNodesManager.ValidatorSwitchToCompoundingRequested(
            address(pod0),
            etherFiNodesManager.calculateValidatorPubkeyHash(pubkeys[0]),
            pubkeys[0]
        );
        vm.prank(address(ETHERFI_OPERATING_ADMIN));
        etherFiNodesManager.requestConsolidation{value: valueToSend}(reqs);

    }

    function test_multiple_switchToCompounding() public {
        console2.log("=== MULTIPLE SWITCH TO COMPOUNDING TEST ===");

        bytes[] memory pubkeys = new bytes[](3);
        uint256[] memory legacyIds = new uint256[](3);
        pubkeys[0] = PK_80143;
        legacyIds[0] = 80143;
        pubkeys[1] = PK_80194;
        legacyIds[1] = 80194;
        pubkeys[2] = PK_89936;
        legacyIds[2] = 89936;

        uint256[] memory linkOnlyOneValidatorlegacyId = new uint256[](1);
        linkOnlyOneValidatorlegacyId[0] = 80143;
        bytes[] memory linkOnlyOneValidatorPubkeys = new bytes[](1);
        linkOnlyOneValidatorPubkeys[0] = PK_80143;

        vm.prank(address(etherFiOperatingTimelock));
        etherFiNodesManager.linkLegacyValidatorIds(linkOnlyOneValidatorlegacyId, linkOnlyOneValidatorPubkeys); 
        vm.stopPrank();  

        ( , IEigenPod pod0) = _resolvePod(pubkeys[0]);

        IEigenPodTypes.ConsolidationRequest[] memory reqs = _switchToCompoundingRequestsFromPubkeys(pubkeys);
        
        uint256 feePer = pod0.getConsolidationRequestFee();
        uint256 n = reqs.length;
        uint256 valueToSend = feePer * n;

        vm.deal(address(ETHERFI_OPERATING_ADMIN), valueToSend + 1 ether);

        vm.prank(address(ETHERFI_OPERATING_ADMIN));
        etherFiNodesManager.requestConsolidation{value: valueToSend}(reqs);

    }
}