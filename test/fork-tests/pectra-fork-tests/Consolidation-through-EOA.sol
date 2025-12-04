// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import "../../src/EtherFiNodesManager.sol";
import "../../src/EtherFiNode.sol";
import "../../src/EtherFiTimelock.sol";
import "../../src/RoleRegistry.sol";
import "../../src/interfaces/IRoleRegistry.sol";
import "../../src/interfaces/IStakingManager.sol";
import "../../src/interfaces/IEtherFiRateLimiter.sol";
import {IEigenPod, IEigenPodTypes } from "../../src/eigenlayer-interfaces/IEigenPod.sol";

/**
 * @title ConsolidationThroughEOATest
 * @notice test for request consolidation
 * @dev Run with: forge test --fork-url <mainnet-rpc> --match-path test/pectra-fork-tests/Consolidation-through-EOA.sol -vvvv
 */

contract ConsolidationThroughEOATest is Test {
    // === MAINNET CONTRACT ADDRESSES ===
    EtherFiNodesManager constant etherFiNodesManager = EtherFiNodesManager(payable(0x8B71140AD2e5d1E7018d2a7f8a288BD3CD38916F));
    RoleRegistry constant roleRegistry = RoleRegistry(0x62247D29B4B9BECf4BB73E0c722cf6445cfC7cE9);
    IStakingManager constant stakingManager = IStakingManager(0x25e821b7197B146F7713C3b89B6A4D83516B912d);
    IEtherFiRateLimiter constant rateLimiter = IEtherFiRateLimiter(0x6C7c54cfC2225fA985cD25F04d923B93c60a02F8);

    EtherFiNodesManager public newEtherFiNodesManagerImpl;

    EtherFiTimelock constant etherFiOperatingTimelock = EtherFiTimelock(payable(0xcD425f44758a08BaAB3C4908f3e3dE5776e45d7a));
    address constant realElExiter = 0x12582A27E5e19492b4FcD194a60F8f5e1aa31B0F;

    bytes constant PK_28689 = hex"88d73705e9c3f29b042d3fe70bdc8781debc5506db43dd00122fd1fa7f4755535d31c7ecb2686ff53669b080ef9e18a3";

    // Consolidate the following validators:
    bytes constant PK_80143 = hex"811cd0bb7dd301afbbddd1d5db15ff0ca9d5f8ada78c0b1223f75b524aca1ca9ff1ba205d9efd7c37c2174576cc123e2";
    bytes constant PK_80194 = hex"b86cb11d564b29a38cdc8a3f1f9c35e6dcd2d0f85f40da60f745e479ba42b4548c83a2b049cf02277fceaa9b421d0039";
    bytes constant PK_89936 = hex"b8786ec7945d737698e374193f05a5498e932e2941263a7842837e9e3fac033af285e53a90afecf994585d178b5eedaa";
    // bytes constant PK_75208 = hex"b87882da67b89b06a59ec23b955ade930b534752153de08a50aa53172ea3439768dce39f547acfee53e55d985d6c4283";

    function setUp() public {
        console2.log("=== SETUP ===");
        //upgrade the etherfi nodes manager contract
        newEtherFiNodesManagerImpl = new EtherFiNodesManager(address(stakingManager), address(roleRegistry), address(rateLimiter));
        vm.prank(roleRegistry.owner());
        etherFiNodesManager.upgradeTo(address(newEtherFiNodesManagerImpl));
        vm.stopPrank();
        console2.log("=== SETUP COMPLETE ===");
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

    function test_ConsolidationThroughEOA() public {
        console2.log("=== CONSOLIDATION THROUGH EOA TEST ===");
        
        // Get the owner address - call it outside of prank context to avoid issues
        address roleRegistryOwner = roleRegistry.owner();
        console2.log("RoleRegistry owner:", roleRegistryOwner);
        
        // Verify we're pranking as the correct owner
        require(roleRegistryOwner != address(0), "RoleRegistry owner is zero address");
        
        // The issue: _enumerableRolesSenderIsContractOwner() makes a staticcall to owner()
        // and checks if msg.sender equals the result. In a proxy context, this can fail.
        // We need to ensure the prank is set up correctly before the grantRole call.
        vm.startPrank(roleRegistryOwner);
        roleRegistry.grantRole(etherFiNodesManager.ETHERFI_NODES_MANAGER_EL_CONSOLIDATION_ROLE(), realElExiter);
        vm.stopPrank();
        // Verify the role was granted
        bool hasRole = roleRegistry.hasRole(etherFiNodesManager.ETHERFI_NODES_MANAGER_EL_CONSOLIDATION_ROLE(), realElExiter);
        require(hasRole, "test: EOA does not have the EL Consolidation Role");
        console2.log("Granted ETHERFI_NODES_MANAGER_EL_CONSOLIDATION_ROLE to EOA:", realElExiter);
        bytes[] memory pubkeys = new bytes[](3);
        pubkeys[0] = PK_80143;
        pubkeys[1] = PK_80194;
        pubkeys[2] = PK_89936;

        bytes[] memory pubkeysonlyOneValidator = new bytes[](1);
        uint256[] memory legacyIdsonlyOneValidator = new uint256[](1);
        pubkeysonlyOneValidator[0] = PK_80143;
        legacyIdsonlyOneValidator[0] = 80143;

        // Link legacy validator id (requires admin role, so use timelock)
        vm.prank(address(etherFiOperatingTimelock));
        etherFiNodesManager.linkLegacyValidatorIds(legacyIdsonlyOneValidator, pubkeysonlyOneValidator);
        vm.stopPrank();
        console2.log("Linking legacy validator ids complete");

        ( , IEigenPod pod0) = _resolvePod(pubkeys[0]);

        IEigenPodTypes.ConsolidationRequest[] memory reqs = _switchToCompoundingRequestsFromPubkeys(pubkeys);

        uint256 feePer = pod0.getConsolidationRequestFee();
        uint256 n = reqs.length;
        uint256 valueToSend = feePer * n;

        // Fund the EOA with enough ETH to pay consolidation fees
        vm.deal(realElExiter, valueToSend + 1 ether);

        // Test that EOA can successfully call requestConsolidation
        vm.expectEmit(true, true, true, true, address(etherFiNodesManager));
        emit IEtherFiNodesManager.ValidatorSwitchToCompoundingRequested(
            address(pod0),
            etherFiNodesManager.calculateValidatorPubkeyHash(pubkeys[0]),
            pubkeys[0]
        );
        
        vm.prank(realElExiter);
        etherFiNodesManager.requestConsolidation{value: valueToSend}(reqs);
        
        console2.log("EOA successfully requested consolidation");
    }

    function test_RequestConsolidation_WithoutRole_Reverts() public {
        console2.log("=== REQUEST CONSOLIDATION WITHOUT ROLE TEST ===");
        
        // Create an EOA address without the role
        address eoaWithoutRole = makeAddr("eoaWithoutRole");
                
        // Verify the EOA does not have the role
        bool hasRole = roleRegistry.hasRole(etherFiNodesManager.ETHERFI_NODES_MANAGER_EL_CONSOLIDATION_ROLE(), eoaWithoutRole);
        require(!hasRole, "test: EOA should not have the EL Consolidation Role");

        bytes[] memory pubkeys = new bytes[](3);
        pubkeys[0] = PK_80143;
        pubkeys[1] = PK_80194;
        pubkeys[2] = PK_89936;

        bytes[] memory pubkeysonlyOneValidator = new bytes[](1);
        uint256[] memory legacyIdsonlyOneValidator = new uint256[](1);
        pubkeysonlyOneValidator[0] = PK_80143;
        legacyIdsonlyOneValidator[0] = 80143;

        // Link legacy validator id (requires admin role, so use timelock)
        vm.prank(address(etherFiOperatingTimelock));
        etherFiNodesManager.linkLegacyValidatorIds(legacyIdsonlyOneValidator, pubkeysonlyOneValidator);
        vm.stopPrank();

        ( , IEigenPod pod0) = _resolvePod(pubkeysonlyOneValidator[0]);

        IEigenPodTypes.ConsolidationRequest[] memory reqs = _switchToCompoundingRequestsFromPubkeys(pubkeys);

        uint256 feePer = pod0.getConsolidationRequestFee();
        uint256 n = reqs.length;
        uint256 valueToSend = feePer * n;

        // Fund the EOA with enough ETH to pay consolidation fees
        vm.deal(eoaWithoutRole, valueToSend + 1 ether);

        // Test that EOA without role cannot call requestConsolidation
        vm.expectRevert();
        vm.prank(eoaWithoutRole);
        etherFiNodesManager.requestConsolidation{value: valueToSend}(reqs);
        
        console2.log("EOA without role correctly reverted");
    }
}