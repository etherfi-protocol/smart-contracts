// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "@etherfi/archive/EtherFiViewer.sol";
import "@etherfi/interfaces/eigenlayer-interfaces/IEigenPod.sol";
import "@etherfi/utils/UUPSProxy.sol";

contract EtherFiViewerLiveTest is Test {
    EtherFiViewer viewer;
    address constant PROVIDER = address(0x1001);
    address constant MANAGER = address(0x1002);
    address constant NODE = address(0x1003);
    address constant POD = address(0x1004);

    function setUp() public {
        vm.mockCall(PROVIDER, abi.encodeWithSignature("getContractAddress(string)", "EtherFiNodesManager"), abi.encode(MANAGER));
        viewer = EtherFiViewer(address(new UUPSProxy(address(new EtherFiViewer()), "")));
        viewer.initialize(PROVIDER);
        vm.mockCall(MANAGER, abi.encodeWithSignature("etherfiNodeAddress(uint256)", uint256(42)), abi.encode(NODE));
    }

    function test_LiveNodeViewsAndSplitBalance() public {
        vm.mockCall(NODE, abi.encodeWithSignature("numAssociatedValidators()"), abi.encode(uint256(3)));
        vm.mockCall(NODE, abi.encodeWithSignature("isRestakingEnabled()"), abi.encode(true));
        vm.mockCall(NODE, abi.encodeWithSignature("eigenPod()"), abi.encode(POD));
        vm.deal(NODE, 2 ether);
        vm.deal(POD, 5 ether);

        address[] memory nodes = new address[](1);
        nodes[0] = NODE;
        (bool countOk, bytes memory counts) = address(viewer).staticcall(abi.encodeWithSignature("EtherFiNode_numAssociatedValidators(address[])", nodes));
        assertTrue(countOk, "live node-count view missing");
        assertEq(abi.decode(counts, (uint256[]))[0], 3);

        uint256[] memory ids = new uint256[](1);
        ids[0] = 42;
        (bool restakedOk, bytes memory restaked) = address(viewer).staticcall(abi.encodeWithSignature("EigenPod_hasRestaked(uint256[])", ids));
        assertTrue(restakedOk, "live restaking view missing");
        assertTrue(abi.decode(restaked, (bool[]))[0]);

        (bool splitOk, bytes memory split) = address(viewer).staticcall(abi.encodeWithSignature("EtherFiNodesManager_splitBalanceInExecutionLayer(uint256[])", ids));
        assertTrue(splitOk, "live balance-split view missing");
        (uint256[] memory nodeBalances, uint256[] memory podBalances, uint256[] memory delayed) = abi.decode(split, (uint256[], uint256[], uint256[]));
        assertEq(nodeBalances[0], 2 ether);
        assertEq(podBalances[0], 5 ether);
        assertEq(delayed[0], 0);
    }

    function test_LivePubkeyViewRetainsBytesArraySignature() public {
        uint256[] memory ids = new uint256[](1);
        ids[0] = 42;
        bytes[][] memory pubkeys = new bytes[][](1);
        pubkeys[0] = new bytes[](1);
        pubkeys[0][0] = hex"0102";
        vm.mockCall(NODE, abi.encodeWithSignature("eigenPod()"), abi.encode(POD));
        vm.mockCall(POD, abi.encodeWithSignature("validatorPubkeyToInfo(bytes)", hex"0102"), abi.encode(uint64(23), uint64(32), uint64(123), uint8(1)));
        (bool ok, bytes memory data) = address(viewer).staticcall(
            abi.encodeWithSignature("EigenPod_validatorPubkeyHashToInfo(uint256[],bytes[][])", ids, pubkeys)
        );
        assertTrue(ok, "live bytes[][] signature missing");
        IEigenPodTypes.ValidatorInfo[][] memory result = abi.decode(data, (IEigenPodTypes.ValidatorInfo[][]));
        assertEq(result[0][0].validatorIndex, 23);
        assertEq(result[0][0].restakedBalanceGwei, 32);
    }
}
