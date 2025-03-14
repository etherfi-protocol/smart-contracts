// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import "forge-std/Test.sol";
import {EtherFiRedemptionManager} from "../src/EtherFiRedemptionManager.sol";
import {TestSetup} from "./TestSetup.sol";

import "forge-std/Test.sol";
import "forge-std/console.sol";


import "../src/eigenlayer-interfaces/IDelayedWithdrawalRouter.sol";
import "../src/eigenlayer-interfaces/IEigenPodManager.sol";
import "../src/eigenlayer-interfaces/IBeaconChainOracle.sol";
import "../src/eigenlayer-interfaces/IDelegationManager.sol";
import "./eigenlayer-mocks/BeaconChainOracleMock.sol";
import "../src/eigenlayer-interfaces/ITimelock.sol";

import "../src/interfaces/IStakingManager.sol";
import "../src/interfaces/IEtherFiNode.sol";
import "../src/interfaces/ILiquidityPool.sol";
import "../src/interfaces/ILiquifier.sol";
import "../src/EtherFiNodesManager.sol";
import "../src/StakingManager.sol";
import "../src/NodeOperatorManager.sol";
import "../src/archive/RegulationsManager.sol";
import "../src/AuctionManager.sol";
import "../src/archive/ProtocolRevenueManager.sol";
import "../src/BNFT.sol";
import "../src/TNFT.sol";
import "../src/Treasury.sol";
import "../src/EtherFiNode.sol";
import "../src/LiquidityPool.sol";
import "../src/Liquifier.sol";
import "../src/EtherFiRestaker.sol";
import "../src/EETH.sol";
import "../src/WeETH.sol";
import "../src/MembershipManager.sol";
import "../src/MembershipNFT.sol";
import "../src/EarlyAdopterPool.sol";
import "../src/TVLOracle.sol";
import "../src/UUPSProxy.sol";
import "../src/WithdrawRequestNFT.sol";
import "../src/NFTExchange.sol";
import "../src/helpers/AddressProvider.sol";
import "./DepositDataGeneration.sol";
import "./DepositContract.sol";
import "./Attacker.sol";
import "./TestERC20.sol";

import "../src/archive/MembershipManagerV0.sol";
import "../src/EtherFiOracle.sol";
import "../src/EtherFiAdmin.sol";
import "../src/EtherFiTimelock.sol";

import "../src/BucketRateLimiter.sol";
import "../src/EtherFiRedemptionManager.sol";

import "../script/ContractCodeChecker.sol";
import "../script/Create2Factory.sol";
import "../src/RoleRegistry.sol";

import "forge-std/Script.sol";

contract TenderlyExecute is Script {
    EtherFiRedemptionManager public redemptionManager;
    EtherFiNodesManager public managerInstance;
    LiquidityPool public liquidityPoolInstance;
    EETH public eETHInstance;
    WeETH public weEthInstance;
    AuctionManager public auctionInstance;
    StakingManager public stakingManagerInstance;
    Treasury public treasuryInstance;
    NodeOperatorManager public nodeOperatorManagerInstance;
    EtherFiNode public node;
    EarlyAdopterPool public earlyAdopterPoolInstance;
    WithdrawRequestNFT public withdrawRequestNFTInstance;
    Liquifier public liquifierInstance;
    EtherFiTimelock public etherFiTimelockInstance;
    EtherFiAdmin public etherFiAdminInstance;
    EtherFiOracle public etherFiOracleInstance;
    AddressProvider public addressProviderInstance;
    DepositDataGeneration public depGen;
    bytes32 zeroRoot = 0x0000000000000000000000000000000000000000000000000000000000000000;

    function _prepareForValidatorRegistration(uint256[] memory _validatorIds) internal returns (IStakingManager.DepositData[] memory, bytes32[] memory, bytes[] memory, bytes[] memory pubKey) {
        IStakingManager.DepositData[] memory depositDataArray = new IStakingManager.DepositData[](_validatorIds.length);
        bytes32[] memory depositDataRootsForApproval = new bytes32[](_validatorIds.length);
        bytes[] memory sig = new bytes[](_validatorIds.length);
        bytes[] memory pubKey = new bytes[](_validatorIds.length);

        for (uint256 i = 0; i < _validatorIds.length; i++) {
            pubKey[i] = hex"8f9c0aab19ee7586d3d470f132842396af606947a0589382483308fdffdaf544078c3be24210677a9c471ce70b3b4c2c";
            bytes32 root = depGen.generateDepositRoot(
                pubKey[i],
                hex"877bee8d83cac8bf46c89ce50215da0b5e370d282bb6c8599aabdbc780c33833687df5e1f5b5c2de8a6cd20b6572c8b0130b1744310a998e1079e3286ff03e18e4f94de8cdebecf3aaac3277b742adb8b0eea074e619c20d13a1dda6cba6e3df",
                managerInstance.getWithdrawalCredentials(_validatorIds[i]),
                1 ether
            );
            depositDataArray[i] = IStakingManager.DepositData({
                publicKey: pubKey[i],
                signature: hex"877bee8d83cac8bf46c89ce50215da0b5e370d282bb6c8599aabdbc780c33833687df5e1f5b5c2de8a6cd20b6572c8b0130b1744310a998e1079e3286ff03e18e4f94de8cdebecf3aaac3277b742adb8b0eea074e619c20d13a1dda6cba6e3df",
                depositDataRoot: root,
                ipfsHashForEncryptedValidatorKey: "test_ipfs"
            });

            depositDataRootsForApproval[i] = depGen.generateDepositRoot(
                pubKey[i],
                hex"ad899d85dcfcc2506a8749020752f81353dd87e623b2982b7bbfbbdd7964790eab4e06e226917cba1253f063d64a7e5407d8542776631b96c4cea78e0968833b36d4e0ae0b94de46718f905ca6d9b8279e1044a41875640f8cb34dc3f6e4de65",
                managerInstance.getWithdrawalCredentials(_validatorIds[i]),
                31 ether
            );

            sig[i] = hex"ad899d85dcfcc2506a8749020752f81353dd87e623b2982b7bbfbbdd7964790eab4e06e226917cba1253f063d64a7e5407d8542776631b96c4cea78e0968833b36d4e0ae0b94de46718f905ca6d9b8279e1044a41875640f8cb34dc3f6e4de65";
        
        }

        return (depositDataArray, depositDataRootsForApproval, sig, pubKey);
    }

    function setUp() public {
        redemptionManager = EtherFiRedemptionManager(payable(address(0x69e03a920FE2e2FcD970fC20095B5cC664DC0C8b)));

        addressProviderInstance = AddressProvider(vm.envAddress("CONTRACT_REGISTRY"));
        managerInstance = EtherFiNodesManager(payable(addressProviderInstance.getContractAddress("EtherFiNodesManager")));
        liquidityPoolInstance = LiquidityPool(payable(addressProviderInstance.getContractAddress("LiquidityPool")));
        eETHInstance = EETH(addressProviderInstance.getContractAddress("EETH"));
        weEthInstance = WeETH(addressProviderInstance.getContractAddress("WeETH"));
        auctionInstance = AuctionManager(addressProviderInstance.getContractAddress("AuctionManager"));
        stakingManagerInstance = StakingManager(addressProviderInstance.getContractAddress("StakingManager"));
        treasuryInstance = Treasury(payable(addressProviderInstance.getContractAddress("Treasury")));
        nodeOperatorManagerInstance = NodeOperatorManager(addressProviderInstance.getContractAddress("NodeOperatorManager"));
        node = EtherFiNode(payable(addressProviderInstance.getContractAddress("EtherFiNode")));
        earlyAdopterPoolInstance = EarlyAdopterPool(payable(addressProviderInstance.getContractAddress("EarlyAdopterPool")));
        withdrawRequestNFTInstance = WithdrawRequestNFT(addressProviderInstance.getContractAddress("WithdrawRequestNFT"));
        liquifierInstance = Liquifier(payable(addressProviderInstance.getContractAddress("Liquifier")));
        etherFiTimelockInstance = EtherFiTimelock(payable(addressProviderInstance.getContractAddress("EtherFiTimelock")));
        etherFiAdminInstance = EtherFiAdmin(payable(addressProviderInstance.getContractAddress("EtherFiAdmin")));
        etherFiOracleInstance = EtherFiOracle(payable(addressProviderInstance.getContractAddress("EtherFiOracle")));


        depGen = new DepositDataGeneration();
    }

    function run() public {
        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        setUp();
        newStakingFlow();
    }

    function newStakingFlow() public {
        uint256 numOfBatches = 10;
        uint256 numValsPerBatch = 60;
        uint256 numValsToRegister = numOfBatches * numValsPerBatch;
       //0x6A54cF0befD629A8F74348Bb622a84A63f944532 
        //uint256[] memory bidIds = auctionInstance.createBid{value: numValsToRegister * 1100000000000000}(numValsToRegister, 1100000000000000);
        uint256[] memory bidIds = new uint256[](numValsToRegister);
        for (uint256 i; i < numValsToRegister; i++) {
            bidIds[i] = i + 87866;
        }
        //liquidityPoolInstance.registerValidatorSpawner(address(0xc351788DDb96cD98d99E62C97f57952A8b3Fc1B5));
        for (uint256 i; i < 1; i++) {
            uint256[] memory bidIdsToRegister = new uint256[](numValsPerBatch);
            for (uint256 j; j < numValsPerBatch; j++) {
                bidIdsToRegister[j] = bidIds[i * numValsPerBatch + j];
            }
            //liquidityPoolInstance.batchDeposit(bidIdsToRegister, numValsPerBatch);
            (IStakingManager.DepositData[] memory depositDataArray, bytes32[] memory depositDataRootsForApproval, bytes[] memory sig, bytes[] memory pubKey) = _prepareForValidatorRegistration(bidIdsToRegister);
            //liquidityPoolInstance.batchRegister(zeroRoot, bidIdsToRegister, depositDataArray, depositDataRootsForApproval, sig);
            liquidityPoolInstance.batchApproveRegistration(bidIdsToRegister, pubKey, sig);
        }
    }
}