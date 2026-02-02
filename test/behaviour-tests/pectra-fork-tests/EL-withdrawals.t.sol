
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "forge-std/console2.sol";
import "../../../src/EtherFiNodesManager.sol";
import "../../../src/EtherFiNode.sol";
import "../../../src/EtherFiTimelock.sol";
import "../../../src/interfaces/IRoleRegistry.sol";
import "../../../src/RoleRegistry.sol";

import {IEigenPod, IEigenPodTypes } from "../../../src/eigenlayer-interfaces/IEigenPod.sol";
import "../../TestSetup.sol";
/**
 * @title ELExitsTest
 * @notice test for EL exits
 * @dev Run with: forge test --fork-url <mainnet-rpc> --match-path test/pectra-fork-tests/EL-exits.t.sol -vvvv
 */

contract ELExitsTest is TestSetup {
    // === MAINNET CONTRACT ADDRESSES ===
    EtherFiNodesManager constant etherFiNodesManager = EtherFiNodesManager(payable(0x8B71140AD2e5d1E7018d2a7f8a288BD3CD38916F));
    RoleRegistry constant roleRegistry = RoleRegistry(0x62247D29B4B9BECf4BB73E0c722cf6445cfC7cE9);

    EtherFiTimelock constant etherFiOperatingTimelock = EtherFiTimelock(payable(0xcD425f44758a08BaAB3C4908f3e3dE5776e45d7a));
    address constant realElExiter = 0x12582A27E5e19492b4FcD194a60F8f5e1aa31B0F;

    bytes constant PK_28689 = hex"88d73705e9c3f29b042d3fe70bdc8781debc5506db43dd00122fd1fa7f4755535d31c7ecb2686ff53669b080ef9e18a3";

    // MULTIPLE EL EXITS TEST
    bytes constant PK_80143 = hex"811cd0bb7dd301afbbddd1d5db15ff0ca9d5f8ada78c0b1223f75b524aca1ca9ff1ba205d9efd7c37c2174576cc123e2";
    bytes constant PK_80194 = hex"b86cb11d564b29a38cdc8a3f1f9c35e6dcd2d0f85f40da60f745e479ba42b4548c83a2b049cf02277fceaa9b421d0039";
    bytes constant PK_89936 = hex"b8786ec7945d737698e374193f05a5498e932e2941263a7842837e9e3fac033af285e53a90afecf994585d178b5eedaa";

    function setUp() public {
        initializeRealisticFork(MAINNET_FORK);
    }

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

        bytes[] memory pubkeys = new bytes[](1);
        uint256[] memory legacyIds = new uint256[](1);
        uint64[] memory amounts = new uint64[](1);

        pubkeys[0] = PK_28689;
        legacyIds[0] = 28689;
        amounts[0] = 0;

        vm.prank(address(realElExiter));
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

    function test_multiple_ELExits() public {
        console2.log("=== MULTIPLE EL EXITS TEST ===");

        bytes[] memory pubkeys = new bytes[](3);
        uint64[] memory amounts = new uint64[](3);

        pubkeys[0] = PK_80194;
        amounts[0] = 0;
        
        pubkeys[1] = PK_89936;
        amounts[1] = 0;

        pubkeys[2] = PK_80143;
        amounts[2] = 0;

        uint256[] memory linkOnlyOneValidatorlegacyId = new uint256[](1);
        linkOnlyOneValidatorlegacyId[0] = 80194;
        bytes[] memory linkOnlyOneValidatorPubkeys = new bytes[](1);
        linkOnlyOneValidatorPubkeys[0] = PK_80194;
        
        vm.prank(address(realElExiter));
        etherFiNodesManager.linkLegacyValidatorIds(linkOnlyOneValidatorlegacyId, linkOnlyOneValidatorPubkeys); 
        vm.stopPrank();  

        ( , IEigenPod pod0) = _resolvePod(pubkeys[0]);
        IEigenPod.WithdrawalRequest[] memory reqs = _requestsFromPubkeys(pubkeys, amounts);

        uint256 feePer = pod0.getWithdrawalRequestFee();
        uint256 n = reqs.length;
        uint256 valueToSend = feePer * n;

        vm.prank(realElExiter);
        etherFiNodesManager.requestExecutionLayerTriggeredWithdrawal{value: valueToSend}(reqs);
        vm.stopPrank();
    }
}