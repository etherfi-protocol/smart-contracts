// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "forge-std/Script.sol";
import "forge-std/console2.sol";
import {Utils, ICreate2Factory} from "../../utils/utils.sol";
import {EtherFiTimelock} from "../../../src/EtherFiTimelock.sol";
import {EtherFiNode} from "../../../src/EtherFiNode.sol";
import {EtherFiRedemptionManager} from "../../../src/EtherFiRedemptionManager.sol";
import {EtherFiRestaker} from "../../../src/EtherFiRestaker.sol";
import {EtherFiRewardsRouter} from "../../../src/EtherFiRewardsRouter.sol";
import {Liquifier} from "../../../src/Liquifier.sol";
import {WithdrawRequestNFT} from "../../../src/WithdrawRequestNFT.sol";
import {EtherFiViewer} from "../../../src/helpers/EtherFiViewer.sol";
import {StakingManager} from "../../../src/StakingManager.sol";
import {LiquidityPool} from "../../../src/LiquidityPool.sol";
import "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import {ContractCodeChecker} from "../../../script/ContractCodeChecker.sol";

/**
 * @title ReauditFixesTransactions
 * @notice Schedules and executes upgrades for re-audit fixes
 * @dev Run with: forge script script/upgrades/reaudit-fixes/transactions-reaudit-fixes.s.sol --fork-url $MAINNET_RPC_URL
 * 
 * Changes being upgraded:
 * - EtherFiNode: Caps ETH transfers by totalValueOutOfLp
 * - EtherFiRedemptionManager: Fee handling order fix & totalRedeemableAmount fix
 * - EtherFiRestaker: Lido withdrawal fix & withdrawEther cap
 * - EtherFiRewardsRouter: withdrawToLiquidityPool cap
 * - Liquifier: stETH rounding fix, withdrawEther cap, simplified getTotalPooledEther
 * - WithdrawRequestNFT: Event emission fix
 * - EtherFiViewer: Changed from validatorPubkeyToInfo to validatorPubkeyHashToInfo
 */
contract ReauditFixesTransactions is Utils {
    EtherFiTimelock etherFiTimelock = EtherFiTimelock(payable(UPGRADE_TIMELOCK));
    ContractCodeChecker contractCodeChecker;
    uint256 constant TIMELOCK_MIN_DELAY = 259200; // 72 hours

    //--------------------------------------------------------------------------------------
    //---------------------------- NEW IMPLEMENTATION ADDRESSES ----------------------------
    //--------------------------------------------------------------------------------------
    address constant etherFiNodeImpl = 0xA91F8a52F0C1b4D3fDC256fC5bEBCA4D627da392;
    address constant etherFiRedemptionManagerImpl = 0xb4fed2BF48EF08b93256AE67ad3bFaB6F1f5c13a;
    address constant etherFiRestakerImpl = 0x9D795b303B9dA3488FD3A4ca4702c872576BD0c6;
    address constant etherFiRewardsRouterImpl = 0x408de8D339F40086c5643EE4778E0F872aB5E423;
    address constant liquifierImpl = 0x0E7489D32D34CCdC12d7092067bf53Aa38bf2BF6;
    address constant withdrawRequestNFTImpl = 0xDdD4278396A22757F2a857ADE3E6Cb35B933f9Cb;
    address constant etherFiViewerImpl = 0x69585767FDAEC9a7c18FeB99D59B5CbEDA740483;

    // Salt used for CREATE2 deployment
    bytes32 constant commitHashSalt = bytes32(bytes20(hex"77381e3f2ef7ac8ff04f2a044e59432e2486195d"));

    function run() public {
        console2.log("================================================");
        console2.log("=== Re-audit Fixes Upgrade Transactions ========");
        console2.log("================================================");
        console2.log("");

        // string memory forkUrl = vm.envString("MAINNET_RPC_URL");
        // vm.selectFork(vm.createFork(forkUrl));

        contractCodeChecker = new ContractCodeChecker();

        // Step 1: Verify deployed bytecode matches expected
        verifyDeployedBytecode();

        // Step 2: Execute upgrade via timelock
        executeUpgrade();

        // Step 3: Verify upgrades were successful
        verifyUpgrades();

        // Step 4: Run fork tests
        forkTests();
    }

    //--------------------------------------------------------------------------------------
    //------------------------------- BYTECODE VERIFICATION --------------------------------
    //--------------------------------------------------------------------------------------
    function verifyDeployedBytecode() public {
        console2.log("=== Verifying Deployed Bytecode ===");
        console2.log("");

        EtherFiNode newEtherFiNodeImplementation = new EtherFiNode(address(LIQUIDITY_POOL), address(ETHERFI_NODES_MANAGER), address(EIGENLAYER_POD_MANAGER), address(EIGENLAYER_DELEGATION_MANAGER), address(ROLE_REGISTRY));
        EtherFiRedemptionManager newEtherFiRedemptionManagerImplementation = new EtherFiRedemptionManager(address(LIQUIDITY_POOL), address(EETH), address(WEETH), address(TREASURY), address(ROLE_REGISTRY), address(ETHERFI_RESTAKER));
        EtherFiRestaker newEtherFiRestakerImplementation = new EtherFiRestaker(address(EIGENLAYER_REWARDS_COORDINATOR), address(ETHERFI_REDEMPTION_MANAGER));
        EtherFiRewardsRouter newEtherFiRewardsRouterImplementation = new EtherFiRewardsRouter(address(LIQUIDITY_POOL), address(TREASURY), address(ROLE_REGISTRY));
        Liquifier newLiquifierImplementation = new Liquifier();
        WithdrawRequestNFT newWithdrawRequestNFTImplementation = new WithdrawRequestNFT(address(TREASURY));
        EtherFiViewer newEtherFiViewerImplementation = new EtherFiViewer(address(EIGENLAYER_POD_MANAGER), address(EIGENLAYER_DELEGATION_MANAGER));

        contractCodeChecker.verifyContractByteCodeMatch(etherFiNodeImpl, address(newEtherFiNodeImplementation));
        contractCodeChecker.verifyContractByteCodeMatch(etherFiRedemptionManagerImpl, address(newEtherFiRedemptionManagerImplementation));
        contractCodeChecker.verifyContractByteCodeMatch(etherFiRestakerImpl, address(newEtherFiRestakerImplementation));
        contractCodeChecker.verifyContractByteCodeMatch(etherFiRewardsRouterImpl, address(newEtherFiRewardsRouterImplementation));
        contractCodeChecker.verifyContractByteCodeMatch(liquifierImpl, address(newLiquifierImplementation));  
        contractCodeChecker.verifyContractByteCodeMatch(withdrawRequestNFTImpl, address(newWithdrawRequestNFTImplementation));
        contractCodeChecker.verifyContractByteCodeMatch(etherFiViewerImpl, address(newEtherFiViewerImplementation));

        console2.log("");
        console2.log("All bytecode verifications passed!");
        console2.log("================================================");
        console2.log("");
    }

    //--------------------------------------------------------------------------------------
    //------------------------------- EXECUTE UPGRADE --------------------------------------
    //--------------------------------------------------------------------------------------
    function executeUpgrade() public {
        console2.log("=== Executing Upgrade ===");
        console2.log("");

        // Build upgrade batch (7 upgrades total)
        address[] memory targets = new address[](6);
        bytes[] memory data = new bytes[](targets.length);
        uint256[] memory values = new uint256[](targets.length); // Default to 0

        //--------------------------------------------------------------------------------------
        //------------------------------- CONTRACT UPGRADES  -----------------------------------
        //--------------------------------------------------------------------------------------
        
        // 1. EtherFiNode (via StakingManager.upgradeEtherFiNode - beacon proxy)
        targets[0] = STAKING_MANAGER;
        data[0] = abi.encodeWithSelector(StakingManager.upgradeEtherFiNode.selector, etherFiNodeImpl);

        // 2. EtherFiRedemptionManager (UUPS)
        targets[1] = ETHERFI_REDEMPTION_MANAGER;
        data[1] = abi.encodeWithSelector(UUPSUpgradeable.upgradeTo.selector, etherFiRedemptionManagerImpl);

        // 3. EtherFiRestaker (UUPS)
        targets[2] = ETHERFI_RESTAKER;
        data[2] = abi.encodeWithSelector(UUPSUpgradeable.upgradeTo.selector, etherFiRestakerImpl);

        // 4. EtherFiRewardsRouter (UUPS)
        targets[3] = ETHERFI_REWARDS_ROUTER;
        data[3] = abi.encodeWithSelector(UUPSUpgradeable.upgradeTo.selector, etherFiRewardsRouterImpl);

        // 5. Liquifier (UUPS)
        targets[4] = LIQUIFIER;
        data[4] = abi.encodeWithSelector(UUPSUpgradeable.upgradeTo.selector, liquifierImpl);

        // 6. WithdrawRequestNFT (UUPS)
        targets[5] = WITHDRAW_REQUEST_NFT;
        data[5] = abi.encodeWithSelector(UUPSUpgradeable.upgradeTo.selector, withdrawRequestNFTImpl);

        // 7. EtherFiViewer (UUPS)
        // NOTE: EtherFiViewer is not being upgraded in this transaction because the owner is an EOA - 0xf8a86ea1Ac39EC529814c377Bd484387D395421e
        // targets[6] = ETHERFI_VIEWER;
        // data[6] = abi.encodeWithSelector(UUPSUpgradeable.upgradeTo.selector, etherFiViewerImpl);

        bytes32 timelockSalt = keccak256(abi.encode(targets, data, "reaudit-fixes-upgrade-v1"));

        // Generate and log schedule calldata
        bytes memory scheduleCalldata = abi.encodeWithSelector(
            etherFiTimelock.scheduleBatch.selector,
            targets,
            values,
            data,
            bytes32(0), // predecessor
            timelockSalt,
            TIMELOCK_MIN_DELAY
        );

        console2.log("=== Schedule Tx Calldata ===");
        console2.log("Target: Upgrade Timelock", UPGRADE_TIMELOCK);
        console2.logBytes(scheduleCalldata);
        console2.log("");

        // Generate and log execute calldata
        bytes memory executeCalldata = abi.encodeWithSelector(
            etherFiTimelock.executeBatch.selector,
            targets,
            values,
            data,
            bytes32(0), // predecessor
            timelockSalt
        );

        console2.log("=== Execute Tx Calldata ===");
        console2.log("Target: Upgrade Timelock", UPGRADE_TIMELOCK);
        console2.logBytes(executeCalldata);
        console2.log("");

        // Execute against fork for testing
        console2.log("=== Scheduling Batch on Fork ===");
        vm.prank(ETHERFI_UPGRADE_ADMIN);
        etherFiTimelock.scheduleBatch(targets, values, data, bytes32(0), timelockSalt, TIMELOCK_MIN_DELAY);

        // Warp past timelock delay
        vm.warp(block.timestamp + TIMELOCK_MIN_DELAY + 1);

        console2.log("=== Executing Batch on Fork ===");
        vm.prank(ETHERFI_UPGRADE_ADMIN);
        etherFiTimelock.executeBatch(targets, values, data, bytes32(0), timelockSalt);

        console2.log("Upgrade executed successfully on fork!");
        console2.log("================================================");
        console2.log("");
    }

    //--------------------------------------------------------------------------------------
    //------------------------------- VERIFY UPGRADES --------------------------------------
    //--------------------------------------------------------------------------------------
    function verifyUpgrades() public view {
        console2.log("=== Verifying Upgrades ===");
        console2.log("");

        // 1. EtherFiNode (beacon proxy - check beacon implementation)
        {
            // The beacon stores the implementation - we need to check it was updated
            StakingManager stakingManager = StakingManager(STAKING_MANAGER);
            address currentImpl = stakingManager.implementation();
            require(currentImpl == etherFiNodeImpl, "EtherFiNode upgrade failed");
            console2.log("EtherFiNode implementation:", currentImpl);
        }

        // 2. EtherFiRedemptionManager
        {
            address currentImpl = getImplementation(ETHERFI_REDEMPTION_MANAGER);
            require(currentImpl == etherFiRedemptionManagerImpl, "EtherFiRedemptionManager upgrade failed");
            console2.log("EtherFiRedemptionManager implementation:", currentImpl);
        }

        // 3. EtherFiRestaker
        {
            address currentImpl = getImplementation(ETHERFI_RESTAKER);
            require(currentImpl == etherFiRestakerImpl, "EtherFiRestaker upgrade failed");
            console2.log("EtherFiRestaker implementation:", currentImpl);
        }

        // 4. EtherFiRewardsRouter
        {
            address currentImpl = getImplementation(ETHERFI_REWARDS_ROUTER);
            require(currentImpl == etherFiRewardsRouterImpl, "EtherFiRewardsRouter upgrade failed");
            console2.log("EtherFiRewardsRouter implementation:", currentImpl);
        }

        // 5. Liquifier
        {
            address currentImpl = getImplementation(LIQUIFIER);
            require(currentImpl == liquifierImpl, "Liquifier upgrade failed");
            console2.log("Liquifier implementation:", currentImpl);
        }

        // 6. WithdrawRequestNFT
        {
            address currentImpl = getImplementation(WITHDRAW_REQUEST_NFT);
            require(currentImpl == withdrawRequestNFTImpl, "WithdrawRequestNFT upgrade failed");
            console2.log("WithdrawRequestNFT implementation:", currentImpl);
        }

        // 7. EtherFiViewer
        // {
        //     address currentImpl = getImplementation(ETHERFI_VIEWER);
        //     require(currentImpl == etherFiViewerImpl, "EtherFiViewer upgrade failed");
        //     console2.log("EtherFiViewer implementation:", currentImpl);
        // }

        console2.log("");
        console2.log("All upgrades verified successfully!");
        console2.log("================================================");
        console2.log("");
    }

    //--------------------------------------------------------------------------------------
    //------------------------------- FORK TESTS -------------------------------------------
    //--------------------------------------------------------------------------------------
    function forkTests() public {
        console2.log("=== Running Fork Tests ===");
        console2.log("");

        testEtherFiRestakerDelegation();
        testLiquifierGetTotalPooledEther();
        testWithdrawRequestNFTBasicFunctionality();

        console2.log("");
        console2.log("All fork tests passed!");
        console2.log("================================================");
        console2.log("");
    }

    function testEtherFiRestakerDelegation() internal view {
        console2.log("Testing EtherFiRestaker delegation check...");
        
        EtherFiRestaker restaker = EtherFiRestaker(payable(ETHERFI_RESTAKER));
        require(restaker.isDelegated(), "EtherFiRestaker: should be delegated");
        
        console2.log("  EtherFiRestaker delegation check passed");
    }

    function testLiquifierGetTotalPooledEther() internal view {
        console2.log("Testing Liquifier getTotalPooledEther...");
        
        Liquifier liquifier = Liquifier(payable(LIQUIFIER));
        uint256 totalPooled = liquifier.getTotalPooledEther();
        
        // Should return a value (even if 0, function should not revert)
        console2.log("  Liquifier getTotalPooledEther:", totalPooled);
        console2.log("  Liquifier getTotalPooledEther check passed");
    }

    function testWithdrawRequestNFTBasicFunctionality() internal view {
        console2.log("Testing WithdrawRequestNFT basic functionality...");
        
        WithdrawRequestNFT withdrawNFT = WithdrawRequestNFT(payable(WITHDRAW_REQUEST_NFT));
        
        // Check name and symbol are accessible (basic sanity check)
        string memory name = withdrawNFT.name();
        string memory symbol = withdrawNFT.symbol();
        
        console2.log("  WithdrawRequestNFT name:", name);
        console2.log("  WithdrawRequestNFT symbol:", symbol);
        console2.log("  WithdrawRequestNFT basic functionality check passed");
    }
}
