// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "./TestSetup.sol";
import "../src/interfaces/ILiquidityPool.sol";

contract NodeOperatorManagerTest is TestSetup {
    event OperatorRegistered(address user, uint64 totalKeys, uint64 keysUsed, bytes ipfsHash);
    event MerkleUpdated(bytes32 oldMerkle, bytes32 indexed newMerkle);

    bytes aliceIPFS_Hash = "QmYsfDjQZfnSQkNyA4eVwswhakCusAx4Z6bzF89FZ91om3";
    bytes bobIPFS_Hash = "QmHsfDjQZfnSQkNyA4eVwswhakCusAx4Z6bzF89FZ91om3";

    function setUp() public {
        setUpTests();
    }

    function test_RegisterNodeOperator() public {
        vm.startPrank(alice);
        nodeOperatorManagerInstance.pauseContract();

        vm.expectRevert("Pausable: paused");
        nodeOperatorManagerInstance.registerNodeOperator(
            aliceIPFS_Hash,
            uint64(10)
        );
        nodeOperatorManagerInstance.unPauseContract();

        nodeOperatorManagerInstance.registerNodeOperator(
            aliceIPFS_Hash,
            uint64(10)
        );
        (
            uint64 totalKeys,
            uint64 keysUsed,
            bytes memory aliceHash
        ) = nodeOperatorManagerInstance.addressToOperatorData(alice);

        assertEq(aliceHash, abi.encodePacked(aliceIPFS_Hash));
        assertEq(totalKeys, 10);
        assertEq(keysUsed, 0);

        assertEq(nodeOperatorManagerInstance.registered(alice), true);
        assertEq(nodeOperatorManagerInstance.isWhitelisted(alice), true);

        vm.expectRevert("Already registered");
        nodeOperatorManagerInstance.registerNodeOperator(
            aliceIPFS_Hash,
            uint64(10)
        );
    }

    function test_RegisterNodeOperatorInMigration() public {

        address[] memory operators = new address[](2);
        operators[0] = address(bob);
        operators[1] = address(alice);

        bytes[] memory hashes = new bytes[](2);
        hashes[0] = bobIPFS_Hash;
        hashes[1] = aliceIPFS_Hash;

        uint64[] memory totalKeys = new uint64[](2);
        totalKeys[0] = 10;
        totalKeys[1] = 15;

        uint64[] memory keysUsed = new uint64[](2);
        keysUsed[0] = 5;
        keysUsed[1] = 1;

        vm.prank(bob);
        vm.expectRevert("Ownable: caller is not the owner");
        nodeOperatorManagerInstance.initializeOnUpgrade(
            operators,
            hashes,
            totalKeys,
            keysUsed
        );

        vm.prank(owner);
        nodeOperatorManagerInstance.initializeOnUpgrade(
            operators,
            hashes,
            totalKeys,
            keysUsed
        );

        (
            uint64 totalKeysUser,
            uint64 keysUsedUser,
            bytes memory bobHash
        ) = nodeOperatorManagerInstance.addressToOperatorData(bob);

        assertEq(bobHash, abi.encodePacked(bobIPFS_Hash));
        assertEq(totalKeysUser, 10);
        assertEq(keysUsedUser, 5);

        assertEq(nodeOperatorManagerInstance.registered(bob), true);

        vm.prank(owner);
        vm.expectRevert("Already registered");
        nodeOperatorManagerInstance.initializeOnUpgrade(
            operators,
            hashes,
            totalKeys,
            keysUsed
        );
    }

    function test_CanAddAddressToWhitelist() public {
        vm.startPrank(alice);
        nodeOperatorManagerInstance.registerNodeOperator(
            aliceIPFS_Hash,
            uint64(10)
        );
        
        assertEq(nodeOperatorManagerInstance.isWhitelisted(jess), false);
        vm.stopPrank();

        vm.expectRevert(NodeOperatorManager.IncorrectRole.selector);
        vm.prank(owner);
        nodeOperatorManagerInstance.addToWhitelist(jess);

        vm.prank(alice);
        nodeOperatorManagerInstance.addToWhitelist(jess);
        assertEq(nodeOperatorManagerInstance.isWhitelisted(jess), true);
    }

    function test_CanRemoveAddressFromWhitelist() public {
        vm.prank(alice);
        nodeOperatorManagerInstance.registerNodeOperator(
            aliceIPFS_Hash,
            uint64(10)
        );

        vm.expectRevert(NodeOperatorManager.IncorrectRole.selector);
        vm.prank(owner);
        nodeOperatorManagerInstance.removeFromWhitelist(alice);

        vm.prank(alice);
        nodeOperatorManagerInstance.removeFromWhitelist(alice);
        assertEq(nodeOperatorManagerInstance.isWhitelisted(alice), false);
    }

    function test_EventOperatorRegistered() public {
        vm.expectEmit(false, false, false, true);
        emit OperatorRegistered(address(alice), 10, 0, aliceIPFS_Hash);
        vm.prank(alice);
        nodeOperatorManagerInstance.registerNodeOperator(
            aliceIPFS_Hash,
            10
        );
    }

    function test_FetchNextKeyIndex() public {
        vm.prank(alice);
        nodeOperatorManagerInstance.registerNodeOperator(
            aliceIPFS_Hash,
            uint64(10)
        );

        (, uint64 keysUsed, ) = nodeOperatorManagerInstance
            .addressToOperatorData(alice);

        assertEq(keysUsed, 0);

        hoax(alice);
        auctionInstance.createBid{value: 0.1 ether}(1, 0.1 ether);

        (, keysUsed, ) = nodeOperatorManagerInstance.addressToOperatorData(
            alice
        );

        assertEq(keysUsed, 1);

        startHoax(0xCd5EBC2dD4Cb3dc52ac66CEEcc72c838B40A5931);
        nodeOperatorManagerInstance.registerNodeOperator(
            aliceIPFS_Hash,
            1
        );
        vm.expectRevert("Insufficient public keys");
        auctionInstance.createBid{value: 0.2 ether}(2, 0.1 ether);
        vm.stopPrank();

        vm.expectRevert("Only auction manager contract function");
        vm.prank(alice);
        nodeOperatorManagerInstance.fetchNextKeyIndex(alice);
    }

    function test_CanOnlySetAddressesOnce() public {
         vm.startPrank(owner);
         vm.expectRevert("Address already set");
         nodeOperatorManagerInstance.setAuctionContractAddress(
             address(0)
        );
    }
}
