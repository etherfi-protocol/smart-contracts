// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "./TestSetup.sol";
import "../lib/murky/src/Merkle.sol";

contract RewardsSkimmingTest is TestSetup {
    uint256 num_operators;
    uint256 num_stakers;
    uint256 num_people;
    address[] operators;
    address[] stakers;
    address[] people;
    uint256[] validatorIds;

    uint256[] validatorIdsOfMixedTNftHolders;
    uint256[] validatorIdsOfTNftsInLiquidityPool;

    uint256[] bidId;

    bytes32 newRoot;
    Merkle merkleStakers;
    bytes32 rootStakers;

    bytes32[] public newWhiteListedAddresses;
    bytes32[] public stakerWhitelistedAddresses;

    function setUp() public {
        num_operators = 1; // should be 1
        num_stakers = 32;
        num_people = num_stakers;
        for (uint i = 0; i < num_operators; i++) {
            operators.push(vm.addr(i+1));
            vm.deal(operators[i], 1 ether);
        }
        for (uint i = 0; i < num_stakers; i++) {
            stakers.push(vm.addr(i+10000));
            vm.deal(stakers[i], 1 ether);
        }
        for (uint i = 0; i < num_people; i++) {
            people.push(vm.addr(i+10000000));
            vm.deal(people[i], 1 ether);
        }    

        setUpTests();
        _setupMerkle();
        _setUpStakerMerkle();

        vm.startPrank(alice);
        nodeOperatorManagerInstance.addToWhitelist(operators[0]);
        vm.stopPrank();

        hoax(alice);
        stakingManagerInstance.setMaxBatchDepositSize(50);

        startHoax(operators[0]);
        nodeOperatorManagerInstance.registerNodeOperator(
            _ipfsHash,
            1000
        );
        for (uint i = 0; i < num_stakers; i++) {
            uint256[] memory ids = auctionInstance.createBid{value: 0.4 ether}(1, 0.4 ether);
            validatorIds.push(ids[0]);
            if (i % 2 == 0) {
                validatorIdsOfMixedTNftHolders.push(ids[0]);
            } else {
                validatorIdsOfTNftsInLiquidityPool.push(ids[0]);
            }
        }
        vm.stopPrank();

        for (uint i = 0; i < num_stakers; i++) {
            startHoax(stakers[i]);

            IStakingManager.DepositData[]
            memory depositDataArray = new IStakingManager.DepositData[](1);

            uint256[] memory candidateBidIds = new uint256[](1);
            candidateBidIds[0] = validatorIds[i];
            bytes32[] memory stakerProof = merkleStakers.getProof(stakerWhitelistedAddresses, i);
            stakingManagerInstance.batchDepositWithBidIds{value: 32 ether}(candidateBidIds, false);

            address etherFiNode = managerInstance.etherfiNodeAddress(candidateBidIds[0]);

            bytes32 root = depGen.generateDepositRoot(
                hex"8f9c0aab19ee7586d3d470f132842396af606947a0589382483308fdffdaf544078c3be24210677a9c471ce70b3b4c2c",
                hex"877bee8d83cac8bf46c89ce50215da0b5e370d282bb6c8599aabdbc780c33833687df5e1f5b5c2de8a6cd20b6572c8b0130b1744310a998e1079e3286ff03e18e4f94de8cdebecf3aaac3277b742adb8b0eea074e619c20d13a1dda6cba6e3df",
                managerInstance.generateWithdrawalCredentials(etherFiNode),
                32 ether
            );
            depositDataArray[0] = IStakingManager.DepositData({
                publicKey: hex"8f9c0aab19ee7586d3d470f132842396af606947a0589382483308fdffdaf544078c3be24210677a9c471ce70b3b4c2c",
                signature: hex"877bee8d83cac8bf46c89ce50215da0b5e370d282bb6c8599aabdbc780c33833687df5e1f5b5c2de8a6cd20b6572c8b0130b1744310a998e1079e3286ff03e18e4f94de8cdebecf3aaac3277b742adb8b0eea074e619c20d13a1dda6cba6e3df",
                depositDataRoot: root,
                ipfsHashForEncryptedValidatorKey: "test_ipfs"
            });
            stakingManagerInstance.batchRegisterValidators(zeroRoot, candidateBidIds, depositDataArray);

            vm.stopPrank();
        }

        // Mix the T-NFT holders
        for (uint i = 0; i < num_stakers; i++) {
            vm.startPrank(stakers[i]);
            if (i % 2 == 0) {
                TNFTInstance.transferFrom(stakers[i], people[i], validatorIds[i]);
            } else {
                TNFTInstance.transferFrom(stakers[i], liquidityPool, validatorIds[i]);
            }
            vm.stopPrank();
        }        
    }

    function _setupMerkle() internal {
        merkle = new Merkle();
        newWhiteListedAddresses.push(
            keccak256(
                abi.encodePacked(operators[0])
            )
        );
        newWhiteListedAddresses.push(
            keccak256(
                abi.encodePacked(operators[0])
            )
        );
        newRoot = merkle.getRoot(newWhiteListedAddresses);
    }

    function _setUpStakerMerkle() internal {
        merkleStakers = new Merkle();

        for(uint256 x; x < 32; x++){
            stakerWhitelistedAddresses.push(keccak256(
                abi.encodePacked(stakers[x])
            ));
        }
        rootStakers = merkleStakers.getRoot(stakerWhitelistedAddresses);
    }

    function _deals() internal {
        vm.deal(liquidityPool, 1 ether);
        vm.deal(address(managerInstance), 100 ether);
        vm.deal(operators[0], 1 ether);
        for (uint i = 0; i < num_stakers; i++) {
            vm.deal(payable(managerInstance.etherfiNodeAddress(i)), 1 ether);
            vm.deal(stakers[i], 1 ether);
            vm.deal(people[i], 1 ether);
        }
    }

    function test_partialWithdraw_batch_base() public {
        _deals();
        startHoax(operators[0]);
        for (uint i = 0; i < num_stakers/2; i++) {
            managerInstance.partialWithdraw(validatorIds[i]);
        }
        vm.stopPrank();
    }
    
    function test_partialWithdrawBatchForTNftInLiquidityPool() public {
        _deals();
        startHoax(operators[0]);
        // managerInstance.partialWithdrawBatchForOperatorAndTNftHolder(operators[0], liquidityPool, validatorIdsOfTNftsInLiquidityPool);
        vm.stopPrank();
    }

}
