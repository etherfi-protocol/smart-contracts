
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import "../../src/EtherFiNodesManager.sol";
import "../../src/EtherFiNode.sol";
import "../../src/EtherFiTimelock.sol";
import "../../src/interfaces/IRoleRegistry.sol";
import {IEigenPod, IEigenPodTypes } from "../../src/eigenlayer-interfaces/IEigenPod.sol";

/**
 * @title ELExitsTest
 * @notice test for EL exits
 * @dev Run with: forge test --fork-url <mainnet-rpc> --match-path test/pectra-fork-tests/EL-exits.t.sol -vvvv
 */

contract ELExitsTest is Test {
    // === MAINNET CONTRACT ADDRESSES ===
    EtherFiNodesManager constant etherFiNodesManager = EtherFiNodesManager(payable(0x8B71140AD2e5d1E7018d2a7f8a288BD3CD38916F));
    RoleRegistry constant roleRegistry = RoleRegistry(0x62247D29B4B9BECf4BB73E0c722cf6445cfC7cE9);

    EtherFiTimelock constant etherFiOperatingTimelock = EtherFiTimelock(payable(0xcD425f44758a08BaAB3C4908f3e3dE5776e45d7a));
    address constant realElExiter = 0x12582A27E5e19492b4FcD194a60F8f5e1aa31B0F;

    bytes constant PK_28689 = hex"88d73705e9c3f29b042d3fe70bdc8781debc5506db43dd00122fd1fa7f4755535d31c7ecb2686ff53669b080ef9e18a3";

    function setUp() public {}

    function _resolvePod(bytes memory pubkey) internal view returns (IEtherFiNode etherFiNode, IEigenPod pod) {
        bytes32 pkHash = etherFiNodesManager.calculateValidatorPubkeyHash(pubkey);
        etherFiNode = etherFiNodesManager.etherFiNodeFromPubkeyHash(pkHash);
        pod = etherFiNode.getEigenPod();
        require(address(pod) != address(0), "test: node has no pod");
    }

    function _requestsFromPubkeys(bytes[] memory pubkeys, uint64[] memory amountsGwei)
        internal
        pure
        returns (IEigenPod.WithdrawalRequest[] memory reqs)
    {
        require(pubkeys.length == amountsGwei.length, "test: length mismatch");
        reqs = new IEigenPod.WithdrawalRequest[](pubkeys.length);
        for (uint256 i = 0; i < pubkeys.length; ++i) {
            // NOTE: IEigenPod.WithdrawalRequest must match your interface type location
            reqs[i] = IEigenPodTypes.WithdrawalRequest({pubkey: pubkeys[i], amountGwei: amountsGwei[i]});
        }
    }

    function test_ELExits() public {
        console2.log("=== EL EXITS TEST ===");
        bool hasRole = roleRegistry.hasRole(etherFiNodesManager.ETHERFI_NODES_MANAGER_EL_TRIGGER_EXIT_ROLE(), realElExiter);
        require(hasRole, "test: realElExiter does not have the EL Trigger Exit Role");

        bytes[] memory pubkeys = new bytes[](1);
        uint256[] memory legacyIds = new uint256[](1);
        uint64[] memory amounts = new uint64[](1);

        pubkeys[0] = PK_28689;
        legacyIds[0] = 28689;
        amounts[0] = 0;

        vm.prank(address(etherFiOperatingTimelock));
        etherFiNodesManager.linkLegacyValidatorIds(legacyIds, pubkeys); 
        vm.stopPrank();  

        ( , IEigenPod pod0) = _resolvePod(pubkeys[0]);

        IEigenPod.WithdrawalRequest[] memory reqs = _requestsFromPubkeys(pubkeys, amounts);

        uint256 feePer = pod0.getWithdrawalRequestFee();
        uint256 n = reqs.length;
        uint256 valueToSend = feePer * n;

        vm.expectEmit(true, true, true, true, address(etherFiNodesManager));
        emit IEtherFiNodesManager.ValidatorWithdrawalRequestSent(
            address(pod0), 
            etherFiNodesManager.calculateValidatorPubkeyHash(pubkeys[0]), 
            pubkeys[0]
        );
        vm.prank(realElExiter);
        etherFiNodesManager.requestExecutionLayerTriggeredWithdrawal{value: valueToSend}(reqs);
        vm.stopPrank();
    }
}