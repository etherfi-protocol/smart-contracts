// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "./TestSetup.sol";

contract BNFTTest is TestSetup {
   function setUp() public {
        setUpTests();
    }

    function test_DisableInitializer() public {
        vm.expectRevert("Initializable: contract is already initialized");
        vm.prank(owner);
        BNFTImplementation.initialize(address(stakingManagerInstance));
    }

    function test_Mint() public {
        startHoax(0xCd5EBC2dD4Cb3dc52ac66CEEcc72c838B40A5931);
        nodeOperatorManagerInstance.registerNodeOperator(
            _ipfsHash,
            5
        );
        uint256[] memory bidIds = auctionInstance.createBid{value: 1 ether}(
            1,
            1 ether
        );
        vm.stopPrank();

        hoax(alice);
        stakingManagerInstance.batchDepositWithBidIds{value: 32 ether}(
            bidIds,
            false
        );

        IStakingManager.DepositData[]
            memory depositDataArray = new IStakingManager.DepositData[](1);

        address etherFiNode = managerInstance.etherfiNodeAddress(1);
        bytes32 root = depGen.generateDepositRoot(
            hex"8f9c0aab19ee7586d3d470f132842396af606947a0589382483308fdffdaf544078c3be24210677a9c471ce70b3b4c2c",
            hex"877bee8d83cac8bf46c89ce50215da0b5e370d282bb6c8599aabdbc780c33833687df5e1f5b5c2de8a6cd20b6572c8b0130b1744310a998e1079e3286ff03e18e4f94de8cdebecf3aaac3277b742adb8b0eea074e619c20d13a1dda6cba6e3df",
            managerInstance.generateWithdrawalCredentials(etherFiNode),
            32 ether
        );

        IStakingManager.DepositData memory depositData = IStakingManager
            .DepositData({
                publicKey: hex"8f9c0aab19ee7586d3d470f132842396af606947a0589382483308fdffdaf544078c3be24210677a9c471ce70b3b4c2c",
                signature: hex"877bee8d83cac8bf46c89ce50215da0b5e370d282bb6c8599aabdbc780c33833687df5e1f5b5c2de8a6cd20b6572c8b0130b1744310a998e1079e3286ff03e18e4f94de8cdebecf3aaac3277b742adb8b0eea074e619c20d13a1dda6cba6e3df",
                depositDataRoot: root,
                ipfsHashForEncryptedValidatorKey: "test_ipfs"
            });
        
        depositDataArray[0] = depositData;


        startHoax(alice);
        stakingManagerInstance.batchRegisterValidators(zeroRoot, bidIds, depositDataArray);
        vm.stopPrank();

        assertEq(BNFTInstance.ownerOf(1), alice);
        assertEq(BNFTInstance.balanceOf(alice), 1);
    }

    function test_BNFTMintsFailsIfNotCorrectCaller() public {
        vm.startPrank(alice);
        vm.expectRevert("Only staking manager contract");
        BNFTInstance.mint(address(alice), 1);
    }

    function test_BNFTCannotBeTransferred() public {
        vm.prank(0xCd5EBC2dD4Cb3dc52ac66CEEcc72c838B40A5931);
        nodeOperatorManagerInstance.registerNodeOperator(
            _ipfsHash,
            5
        );

        startHoax(0xCd5EBC2dD4Cb3dc52ac66CEEcc72c838B40A5931);

        auctionInstance.createBid{value: 0.1 ether}(1, 0.1 ether);

        uint256[] memory bidIdArray = new uint256[](1);
        bidIdArray[0] = 1;

        stakingManagerInstance.batchDepositWithBidIds{value: 32 ether}(
            bidIdArray,
            false
        );

        IStakingManager.DepositData[]
            memory depositDataArray = new IStakingManager.DepositData[](1);

        address etherFiNode = managerInstance.etherfiNodeAddress(1);
        bytes32 root = depGen.generateDepositRoot(
            hex"8f9c0aab19ee7586d3d470f132842396af606947a0589382483308fdffdaf544078c3be24210677a9c471ce70b3b4c2c",
            hex"877bee8d83cac8bf46c89ce50215da0b5e370d282bb6c8599aabdbc780c33833687df5e1f5b5c2de8a6cd20b6572c8b0130b1744310a998e1079e3286ff03e18e4f94de8cdebecf3aaac3277b742adb8b0eea074e619c20d13a1dda6cba6e3df",
            managerInstance.generateWithdrawalCredentials(etherFiNode),
            32 ether
        );

        IStakingManager.DepositData memory depositData = IStakingManager
            .DepositData({
                publicKey: hex"8f9c0aab19ee7586d3d470f132842396af606947a0589382483308fdffdaf544078c3be24210677a9c471ce70b3b4c2c",
                signature: hex"877bee8d83cac8bf46c89ce50215da0b5e370d282bb6c8599aabdbc780c33833687df5e1f5b5c2de8a6cd20b6572c8b0130b1744310a998e1079e3286ff03e18e4f94de8cdebecf3aaac3277b742adb8b0eea074e619c20d13a1dda6cba6e3df",
                depositDataRoot: root,
                ipfsHashForEncryptedValidatorKey: "test_ipfs"
            });

        depositDataArray[0] = depositData;

        stakingManagerInstance.batchRegisterValidators(zeroRoot, bidIdArray, depositDataArray);

        vm.expectRevert("Err: token is SOUL BOUND");
        BNFTInstance.transferFrom(
            0xCd5EBC2dD4Cb3dc52ac66CEEcc72c838B40A5931,
            address(alice),
            1
        );
    }
}
