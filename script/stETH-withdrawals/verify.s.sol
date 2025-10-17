// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "forge-std/Script.sol";
import "forge-std/Test.sol";
import {Utils} from "../utils/utils.sol";
import {ContractCodeChecker} from "../ContractCodeChecker.sol";
import {LiquidityPool} from "../../src/LiquidityPool.sol";
import {EtherFiRestaker} from "../../src/EtherFiRestaker.sol";
import {EtherFiRedemptionManagerTemp} from "../../src/EtherFiRedemptionManagerTemp.sol";
import {EtherFiRedemptionManager} from "../../src/EtherFiRedemptionManager.sol";
import {RedemptionInfo} from "../../src/EtherFiRedemptionManager.sol";
import {BucketLimiter} from "lib/BucketLimiter.sol";
import {ICreate2Factory} from "../utils/utils.sol";

contract VerifyStETHWithdrawals is Script, Test, Utils {
    bytes32 commitHashSalt = bytes32(bytes20(hex"037da63f453b943e7bd96c155e0798003094e4a0"));
    ICreate2Factory constant factory = ICreate2Factory(0x356d1B83970CeF2018F2c9337cDdb67dff5AEF99);
    address constant ETH = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    //--------------------------------------------------------------------------------------
    //---------------------------- New Deployments -----------------------------------------
    //--------------------------------------------------------------------------------------

    address constant newLiquidityPoolImpl = 0xA5C1ddD9185901E3c05E0660126627E039D0a626;
    address constant newEtherFiRedemptionManagerTempImpl = 0x590015FDf9334594B0Ae14f29b0dEd9f1f8504Bc;
    address constant newEtherFiRestakerImpl = 0x71bEf55739F0b148E2C3e645FDE947f380C48615;
    address constant newEtherFiRedemptionManagerImpl = 0xE3F384Dc7002547Dd240AC1Ad69a430CCE1e292d;

    //--------------------------------------------------------------------------------------
    //------------------------- Existing Users/Proxies -------------------------------------
    //--------------------------------------------------------------------------------------
    // address rewardsCoordinator = 0x7750d328b314EfFa365A0402CcfD489B80B0adda; // Eigen Layer Rewards Coordinator - https://etherscan.io/address/0x7750d328b314effa365a0402ccfd489b80b0adda
    // address  etherFiRedemptionManager = 0xDadEf1fFBFeaAB4f68A9fD181395F68b4e4E7Ae0;
    // address  eETH = 0x35fA164735182de50811E8e2E824cFb9B6118ac2;
    // address  weETH = 0xCd5fE23C85820F7B72D0926FC9b05b43E359b7ee;
    // address  stETH = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;
    // address  liquidityPool = 0x308861A430be4cce5502d0A12724771Fc6DaF216;
    // address  operatingTimelock = 0xcD425f44758a08BaAB3C4908f3e3dE5776e45d7a;
    // address  roleRegistry = 0x62247D29B4B9BECf4BB73E0c722cf6445cfC7cE9;
    // address  treasury = 0x0c83EAe1FE72c390A02E426572854931EefF93BA;
    // address  etherFiRestaker = 0x1B7a4C3797236A1C37f8741c0Be35c2c72736fFf;

    address REWARDS_COORDINATOR;
    address ETHERFI_REDEMPTION_MANAGER_PROXY;
    address EETH_PROXY;
    address WEETH_PROXY;
    address STETH_PROXY;
    address LIQUIDITY_POOL_PROXY;
    address OPERATING_TIMELOCK;
    address ROLE_REGISTRY_PROXY;
    address TREASURY_PROXY;
    address ETHERFI_RESTAKER_PROXY;
    ContractCodeChecker checker;
    //--------------------------------------------------------------------------------------
    //-----------------------------  OLD EFRM SELECTORS  -----------------------------------
    //--------------------------------------------------------------------------------------
    bytes4 constant SET_EXIT_FEE_BASIS_POINTS_SELECTOR = 0xad0cba24;
    bytes4 constant SET_EXIT_FEE_SPLIT_TO_TREASURY_IN_BPS_SELECTOR = 0x69b095a2;
    bytes4 constant SET_LOW_WATERMARK_IN_BPS_OF_TVL_SELECTOR = 0x298f3f03;
    bytes4 constant SET_REFILL_RATE_PER_SECOND_SELECTOR = 0x2f530824;
    bytes4 constant SET_CAPACITY_SELECTOR = 0x91915ef8;

    function setUp() public {
        checker = new ContractCodeChecker();

        REWARDS_COORDINATOR = 0x7750d328b314EfFa365A0402CcfD489B80B0adda; 
        ETHERFI_REDEMPTION_MANAGER_PROXY = 0xDadEf1fFBFeaAB4f68A9fD181395F68b4e4E7Ae0;
        EETH_PROXY = 0x35fA164735182de50811E8e2E824cFb9B6118ac2;
        WEETH_PROXY = 0xCd5fE23C85820F7B72D0926FC9b05b43E359b7ee;
        STETH_PROXY = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;
        LIQUIDITY_POOL_PROXY = 0x308861A430be4cce5502d0A12724771Fc6DaF216;
        OPERATING_TIMELOCK = 0xcD425f44758a08BaAB3C4908f3e3dE5776e45d7a;
        ROLE_REGISTRY_PROXY = 0x62247D29B4B9BECf4BB73E0c722cf6445cfC7cE9;
        TREASURY_PROXY = 0x0c83EAe1FE72c390A02E426572854931EefF93BA;
        ETHERFI_RESTAKER_PROXY = 0x1B7a4C3797236A1C37f8741c0Be35c2c72736fFf;
    }

    function run() external {

        console2.log("========================================");
        console2.log("Starting StETH Withdrawals Verification");
        console2.log("========================================\n");

        // 0. Verify addresses
        console2.log("0. VERIFYING ADDRESSES");
        console2.log("----------------------------------------");
        verifyAddresses();

        // 1. Verify bytecode match
        console2.log("1. VERIFYING BYTECODE MATCH");
        console2.log("----------------------------------------");
        verifyBytecode();

        // 2. Verify Upgradeability for Implementations
        console2.log("2. VERIFYING UPGRADEABILITY");
        console2.log("----------------------------------------");
        verifyUpgradeability();
        console2.log("");

        // 3. Verify New Functionality
        console2.log("3. VERIFYING NEW FUNCTIONALITY");
        console2.log("----------------------------------------");
        verifyNewFunctionality();

        console2.log("========================================");
        console2.log("All Verifications Passed");
        console2.log("========================================");
    }

    function verifyUpgradeability() public {
        // ────────────────────────────────────────────────────────────────────────────
        // Individual proxy checks
        // ────────────────────────────────────────────────────────────────────────────
        verifyProxyUpgradeability(address(LIQUIDITY_POOL_PROXY), "LiquidityPool");
        verifyProxyUpgradeability(address(ETHERFI_RESTAKER_PROXY), "EtherFiRestaker");
        verifyProxyUpgradeability(address(ETHERFI_REDEMPTION_MANAGER_PROXY), "EtherFiRedemptionManager");
    }

    function verifyBytecode() public {
        LiquidityPool liquidityPoolImplementation = new LiquidityPool();
        EtherFiRestaker etherFiRestakerImplementation = new EtherFiRestaker(address(REWARDS_COORDINATOR), address(ETHERFI_REDEMPTION_MANAGER_PROXY));
        EtherFiRedemptionManagerTemp etherFiRedemptionManagerTempImplementation = new EtherFiRedemptionManagerTemp(address(LIQUIDITY_POOL_PROXY), address(EETH_PROXY), address(WEETH_PROXY), address(TREASURY_PROXY), address(ROLE_REGISTRY_PROXY));
        EtherFiRedemptionManager etherFiRedemptionManagerImplementation = new EtherFiRedemptionManager(address(LIQUIDITY_POOL_PROXY), address(EETH_PROXY), address(WEETH_PROXY), address(TREASURY_PROXY), address(ROLE_REGISTRY_PROXY), address(ETHERFI_RESTAKER_PROXY));
        
        console2.log(unicode"✓ Checking Bytecode for LiquidityPool:", address(newLiquidityPoolImpl));
        console2.log("liquidityPoolImplementation:", address(liquidityPoolImplementation));
        checker.verifyContractByteCodeMatch(address(newLiquidityPoolImpl), address(liquidityPoolImplementation));
        console2.log("----------------------------------------");
        console2.log(unicode"✓ Checking Bytecode for EtherFiRestaker:", address(newEtherFiRestakerImpl));
        console2.log("etherFiRestakerImplementation:", address(etherFiRestakerImplementation));
        checker.verifyContractByteCodeMatch(address(newEtherFiRestakerImpl), address(etherFiRestakerImplementation));
        console2.log("----------------------------------------");
        console2.log(unicode"✓ Checking Bytecode for EtherFiRedemptionManager:", address(newEtherFiRedemptionManagerImpl));
        console2.log("etherFiRedemptionManagerImplementation:", address(etherFiRedemptionManagerImplementation));
        checker.verifyContractByteCodeMatch(address(newEtherFiRedemptionManagerImpl), address(etherFiRedemptionManagerImplementation));
        console2.log("----------------------------------------");
        console2.log(unicode"✓ Checking Bytecode for EtherFiRedemptionManagerTemp:", address(newEtherFiRedemptionManagerTempImpl));
        console2.log("etherFiRedemptionManagerTempImplementation:", address(etherFiRedemptionManagerTempImplementation));
        checker.verifyContractByteCodeMatch(address(newEtherFiRedemptionManagerTempImpl), address(etherFiRedemptionManagerTempImplementation));
    }

    function verifyAddresses() public {
        address liquidityPoolImplementation;
        address etherFiRestakerImplementation;
        address etherFiRedemptionManagerImplementation;
        address etherFiRedemptionManagerTempImplementation;

        // EtherFiRedemptionManager
        {
            string memory contractName = "EtherFiRedemptionManagerTemp";
            bytes memory constructorArgs = abi.encode(
                address(LIQUIDITY_POOL_PROXY),
                address(EETH_PROXY),
                address(WEETH_PROXY),
                address(TREASURY_PROXY),
                address(ROLE_REGISTRY_PROXY)
            );
            bytes memory bytecode = abi.encodePacked(
                type(EtherFiRedemptionManagerTemp).creationCode,
                constructorArgs
            );
            etherFiRedemptionManagerTempImplementation = verifyCreate2Address(contractName, constructorArgs, bytecode, commitHashSalt, true, factory);
        }

        // EtherFiRestaker
        {
            string memory contractName = "EtherFiRestaker";
            bytes memory constructorArgs = abi.encode(
                address(REWARDS_COORDINATOR),
                address(ETHERFI_REDEMPTION_MANAGER_PROXY)
            );
            bytes memory bytecode = abi.encodePacked(
                type(EtherFiRestaker).creationCode,
                constructorArgs
            );
            etherFiRestakerImplementation = verifyCreate2Address(contractName, constructorArgs, bytecode, commitHashSalt, true, factory);
        }

        // EtherFiRedemptionManager
        {
            string memory contractName = "EtherFiRedemptionManager";
            bytes memory constructorArgs = abi.encode(
                address(LIQUIDITY_POOL_PROXY),
                address(EETH_PROXY),
                address(WEETH_PROXY),
                address(TREASURY_PROXY),
                address(ROLE_REGISTRY_PROXY),
                address(ETHERFI_RESTAKER_PROXY)
            );
            bytes memory bytecode = abi.encodePacked(
                type(EtherFiRedemptionManager).creationCode,
                constructorArgs
            );
            etherFiRedemptionManagerImplementation = verifyCreate2Address(contractName, constructorArgs, bytecode, commitHashSalt, true, factory);
        }

        // LiquidityPool
        {
            string memory contractName = "LiquidityPool";
            bytes memory constructorArgs = abi.encode(
            );
            bytes memory bytecode = abi.encodePacked(
                type(LiquidityPool).creationCode,
                constructorArgs
            );
            liquidityPoolImplementation = verifyCreate2Address(contractName, constructorArgs, bytecode, commitHashSalt, true, factory);
        }

        assertEq(liquidityPoolImplementation, newLiquidityPoolImpl);
        assertEq(etherFiRestakerImplementation, newEtherFiRestakerImpl);
        assertEq(etherFiRedemptionManagerImplementation, newEtherFiRedemptionManagerImpl);
        assertEq(etherFiRedemptionManagerTempImplementation, newEtherFiRedemptionManagerTempImpl);

        console2.log("----------------------------------------");
        console2.log("All Addresses Verified");
        console2.log("----------------------------------------");
    }

    function verifyNewFunctionality() public {
        // ────────────────────────────────────────────────────────────────────────────
        // Verify new functionality
        // ────────────────────────────────────────────────────────────────────────────

        LiquidityPool liquidityPoolInstance = LiquidityPool(payable(LIQUIDITY_POOL_PROXY));    
        bytes4 selector1 = liquidityPoolInstance.burnEEthSharesForNonETHWithdrawal.selector;
        console2.log(unicode"✓ burnEEthSharesForNonETHWithdrawal exists:", vm.toString(selector1));

        EtherFiRestaker etherFiRestakerInstance = EtherFiRestaker(payable(ETHERFI_RESTAKER_PROXY));
        bytes4 selector2 = etherFiRestakerInstance.transferStETH.selector;
        console2.log(unicode"✓ transferStETH exists:", vm.toString(selector2));

        EtherFiRedemptionManager etherFiRedemptionManagerInstance = EtherFiRedemptionManager(payable(ETHERFI_REDEMPTION_MANAGER_PROXY));
        (BucketLimiter.Limit memory limit, uint16 exitFeeSplitToTreasuryInBps, uint16 exitFeeInBps, uint16 lowWatermarkInBpsOfTvl) = etherFiRedemptionManagerInstance.tokenToRedemptionInfo(address(ETH));
        console2.log(unicode"✓ exitFeeSplitToTreasuryInBps exists:", exitFeeSplitToTreasuryInBps);
        console2.log(unicode"✓ exitFeeInBps exists:", exitFeeInBps);
        console2.log(unicode"✓ lowWatermarkInBpsOfTvl exists:", lowWatermarkInBpsOfTvl);

        (BucketLimiter.Limit memory limit2, uint16 exitFeeSplitToTreasuryInBps2, uint16 exitFeeInBps2, uint16 lowWatermarkInBpsOfTvl2) = etherFiRedemptionManagerInstance.tokenToRedemptionInfo(address(STETH_PROXY));
        console2.log(unicode"✓ exitFeeSplitToTreasuryInBps2 exists:", exitFeeSplitToTreasuryInBps2);
        console2.log(unicode"✓ exitFeeInBps2 exists:", exitFeeInBps2);
        console2.log(unicode"✓ lowWatermarkInBpsOfTvl2 exists:", lowWatermarkInBpsOfTvl2);

        assertNotEq(etherFiRedemptionManagerInstance.setExitFeeBasisPoints.selector, SET_EXIT_FEE_BASIS_POINTS_SELECTOR);
        assertNotEq(etherFiRedemptionManagerInstance.setExitFeeSplitToTreasuryInBps.selector, SET_EXIT_FEE_SPLIT_TO_TREASURY_IN_BPS_SELECTOR);
        assertNotEq(etherFiRedemptionManagerInstance.setLowWatermarkInBpsOfTvl.selector, SET_LOW_WATERMARK_IN_BPS_OF_TVL_SELECTOR);
        assertNotEq(etherFiRedemptionManagerInstance.setRefillRatePerSecond.selector, SET_REFILL_RATE_PER_SECOND_SELECTOR);
        assertNotEq(etherFiRedemptionManagerInstance.setCapacity.selector, SET_CAPACITY_SELECTOR);
    }   
}