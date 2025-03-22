// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import "forge-std/Test.sol";
import {TestSetup} from "./TestSetup.sol";
import {EtherFiRedemptionManager} from "../src/EtherFiRedemptionManager.sol";
import {EETH} from "../src/eETH.sol";
import {EtherFiAdmin} from "../src/EtherFiAdmin.sol";
import {LiquidityPool} from "../src/LiquidityPool.sol";
import {AuctionManager} from "../src/AuctionManager.sol";
import {IStakingManager} from "../src/interfaces/IStakingManager.sol";

contract TenderlyTest is TestSetup {
    EtherFiRedemptionManager public redemptionManager;

    function setUp() public {
        initializeRealisticFork(MAINNET_FORK);
        redemptionManager = EtherFiRedemptionManager(payable(address(0x69e03a920FE2e2FcD970fC20095B5cC664DC0C8b)));
    }

    function test_EtherFiRedemptionManagerWithdrawal() public {
        vm.startPrank(address(0x7f7b39E09d1E2fA470AB5c68bD270538A8590EEa));
        uint256 balanceBefore = eETHInstance.balanceOf(address(0x7f7b39E09d1E2fA470AB5c68bD270538A8590EEa));
        uint256 etherBalanceBefore = address(0x7f7b39E09d1E2fA470AB5c68bD270538A8590EEa).balance;
        eETHInstance.approve(address(0x7f7b39E09d1E2fA470AB5c68bD270538A8590EEa), 200 ether);
        redemptionManager.redeemEEth(200 ether, address(0x7f7b39E09d1E2fA470AB5c68bD270538A8590EEa));
        uint256 balanceAfter = eETHInstance.balanceOf(address(0x7f7b39E09d1E2fA470AB5c68bD270538A8590EEa));
    }

    function test_AsyncAdminTask() public {
        vm.startPrank(address(0x7f7b39E09d1E2fA470AB5c68bD270538A8590EEa));
        redemptionManager.initialize(100, 100, 100, 100, 100);
    }

    function test_newStakingFlow() public {
        uint256 numOfBatches = 10;
        uint256 numValsPerBatch = 60;
        uint256 numValsToRegister = numOfBatches * numValsPerBatch;
        
        vm.deal(address(0x6A54cF0befD629A8F74348Bb622a84A63f944532), 10 ether);
        vm.prank(address(0x6A54cF0befD629A8F74348Bb622a84A63f944532));
        uint256[] memory bidIds = auctionInstance.createBid{value: numValsToRegister * 1100000000000000}(numValsToRegister, 1100000000000000);
        //return
        // return;
        // vm.startPrank(address(0xc351788DDb96cD98d99E62C97f57952A8b3Fc1B5));
        // liquidityPoolInstance.registerValidatorSpawner(address(0xc351788DDb96cD98d99E62C97f57952A8b3Fc1B5));
        // for (uint256 i; i < numOfBatches; i++) {
        //     uint256[] memory bidIdsToRegister = new uint256[](numValsPerBatch);
        //     for (uint256 j; j < numValsPerBatch; j++) {
        //         bidIdsToRegister[j] = bidIds[i * numValsPerBatch + j];
        //     }
        //     liquidityPoolInstance.batchDeposit(bidIdsToRegister, numValsPerBatch);
        //     (IStakingManager.DepositData[] memory depositDataArray, bytes32[] memory depositDataRootsForApproval, bytes[] memory sig, bytes[] memory pubKey) = _prepareForValidatorRegistration(bidIdsToRegister);
        //     liquidityPoolInstance.batchRegister(zeroRoot, bidIdsToRegister, depositDataArray, depositDataRootsForApproval, sig);
        //     liquidityPoolInstance.batchApproveRegistration(bidIdsToRegister, pubKey, sig);
        // }
        // vm.stopPrank();
    }


    function test_etherFiAdmin() public {
        vm.startPrank(address(0x7f7b39E09d1E2fA470AB5c68bD270538A8590EEa));
    }
}