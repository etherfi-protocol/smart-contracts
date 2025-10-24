// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "../../../src/EtherFiTimelock.sol";
import "../../../src/interfaces/IEtherFiNode.sol";
import "../../../src/EtherFiNodesManager.sol";
import {IEigenPod, IEigenPodTypes} from "../../../src/eigenlayer-interfaces/IEigenPod.sol";
import "forge-std/Script.sol";
import "forge-std/console2.sol";

/**
forge script script/el-exits/pectra-executions/Consolidate-validators.s.sol:ConsolidateValidators --fork-url <mainnet-rpc> -vvvv
*/

contract ConsolidateValidators is Script {
    EtherFiTimelock etherFiTimelock =
    EtherFiTimelock(payable(0x9f26d4C958fD811A1F59B01B86Be7dFFc9d20761));
    EtherFiTimelock etherFiOperatingTimelock = EtherFiTimelock(payable(0xcD425f44758a08BaAB3C4908f3e3dE5776e45d7a));

    //--------------------------------------------------------------------------------------
    //------------------------- Existing Users/Proxies -------------------------------------
    //--------------------------------------------------------------------------------------
    address constant ETHERFI_NODES_MANAGER_ADDRESS =
        0x8B71140AD2e5d1E7018d2a7f8a288BD3CD38916F;

    EtherFiNodesManager etherFiNodesManager = EtherFiNodesManager(payable(ETHERFI_NODES_MANAGER_ADDRESS));

    address constant ETHERFI_NODES_MANAGER_ADMIN_ROLE = 0x2aCA71020De61bb532008049e1Bd41E451aE8AdC;

    address constant EIGEN_POD_ADDRESS = 0x9563794BEf554667f4650eaAe192FfeC1C656C23; // 20 validators

    address constant ETHERFI_OPERATING_ADMIN =
        0x2aCA71020De61bb532008049e1Bd41E451aE8AdC;
    address constant TIMELOCK_CONTROLLER = 0xcdd57D11476c22d265722F68390b036f3DA48c21;

    address constant EL_TRIGGER_EXITER = 0x12582A27E5e19492b4FcD194a60F8f5e1aa31B0F;

    uint256 MIN_DELAY_OPERATING_TIMELOCK = 28800; // 8 hours
    uint256 MIN_DELAY_TIMELOCK = 259200; // 72 hours

    //consolidate the following validators:
    bytes constant PK_54043 = hex"8014c4704f081bd4b8470cb93722601095a314c3db7ccf79c129189d01c432db968a64131f23a94c8ff1e280500ae3d3"; // linked in EtherfiNodesManager
    bytes constant PK_54045 = hex"820cf0499d0d908d10c19d85027ed4077322096cd4fb322a763c3bf5e4eb70db30b44ef1284e6fb713421a195735d942";
    // bytes constant PK_54041 = hex"87d657860a8b0450d7e700d60aa88a42ee5e6fdedeeb25dd3aee7e1112697f837b4b2e94d37167a900921e6b90c7f3ac";

    function run() public {
        console2.log("================================================");
        console2.log("======================== Running Consolidate Validators ========================");
        console2.log("================================================");
        console2.log("");

        uint256[] memory legacyIdsForOneValidator = new uint256[](1);
        legacyIdsForOneValidator[0] = 54043;
        bytes[] memory pubkeysForOneValidator = new bytes[](1);
        pubkeysForOneValidator[0] = PK_54043;

        vm.prank(address(etherFiOperatingTimelock));
        etherFiNodesManager.linkLegacyValidatorIds(legacyIdsForOneValidator, pubkeysForOneValidator); 
        vm.stopPrank();
        console2.log("Linking legacy validator ids for one validator complete");

        bytes[] memory validatorPubkeys = new bytes[](2);
        validatorPubkeys[0] = PK_54043;
        validatorPubkeys[1] = PK_54045;
        // validatorPubkeys[2] = PK_54041;

        ( , IEigenPod pod0) = _resolvePod(validatorPubkeys[0]);

        IEigenPodTypes.ConsolidationRequest[] memory reqs = _consolidationRequestsFromPubkeys(validatorPubkeys);

        uint256 feePer = pod0.getConsolidationRequestFee();
        uint256 n = reqs.length;
        uint256 valueToSend = feePer * n;
        
        vm.deal(address(etherFiOperatingTimelock), valueToSend + 1 ether);

        vm.prank(address(etherFiOperatingTimelock));
        etherFiNodesManager.requestConsolidation{value: valueToSend}(reqs);
        vm.stopPrank();
        // calling requestConsolidation again to test the revert
        vm.prank(address(etherFiOperatingTimelock));
        etherFiNodesManager.requestConsolidation{value: valueToSend}(reqs);
        vm.stopPrank();

    }

    function _consolidationRequestsFromPubkeys(bytes[] memory pubkeys)
        internal
        pure
        returns (IEigenPodTypes.ConsolidationRequest[] memory reqs) {
        reqs = new IEigenPodTypes.ConsolidationRequest[](pubkeys.length);
        for (uint256 i = 0; i < pubkeys.length; ++i) {
            reqs[i] = IEigenPodTypes.ConsolidationRequest({
                srcPubkey: pubkeys[i],
                targetPubkey: PK_54043 // same pod consolidation
            });
        }
    }

    function _resolvePod(bytes memory pubkey) internal view returns (IEtherFiNode etherFiNode, IEigenPod pod) {
        bytes32 pkHash = etherFiNodesManager.calculateValidatorPubkeyHash(pubkey);
        etherFiNode = etherFiNodesManager.etherFiNodeFromPubkeyHash(pkHash);
        pod = etherFiNode.getEigenPod();
        require(address(pod) != address(0), "test: node has no pod");
    }
}