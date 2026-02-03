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
    address constant withdrawRequestNFTImpl = 0x2f4A5921FcAB46F1F3154e8b42Fc189e08fae3Ed;
    address constant etherFiViewerImpl = 0x69585767FDAEC9a7c18FeB99D59B5CbEDA740483;

    //--------------------------------------------------------------------------------------
    //---------------------------- IMMUTABLE SNAPSHOTS (PRE-UPGRADE) -----------------------
    //--------------------------------------------------------------------------------------
    ImmutableSnapshot internal preRedemptionManagerImmutables;
    ImmutableSnapshot internal preRestakerImmutables;
    ImmutableSnapshot internal preRewardsRouterImmutables;
    ImmutableSnapshot internal preWithdrawRequestNFTImmutables;

    //--------------------------------------------------------------------------------------
    //---------------------------- ACCESS CONTROL SNAPSHOTS (PRE-UPGRADE) ------------------
    //--------------------------------------------------------------------------------------
    address internal preRedemptionManagerOwner;
    address internal preRestakerOwner;
    address internal preRewardsRouterOwner;
    address internal preLiquifierOwner;
    address internal preWithdrawRequestNFTOwner;

    bool internal preRedemptionManagerPaused;
    bool internal preLiquifierPaused;

    // Salt used for CREATE2 deployment
    bytes32 constant commitHashSalt = bytes32(bytes20(hex"77381e3f2ef7ac8ff04f2a044e59432e2486195d"));

    function run() public {
        console2.log("================================================");
        console2.log("=== Re-audit Fixes Upgrade Transactions ========");
        console2.log("================================================");
        console2.log("");

        contractCodeChecker = new ContractCodeChecker();

        // Step 1: Verify deployed bytecode matches expected
        verifyDeployedBytecode();

        // Step 2: Take pre-upgrade snapshots (immutables, access control)
        takePreUpgradeSnapshots();

        // Step 3: Execute upgrade via timelock
        executeUpgrade();

        // Step 4: Verify upgrades were successful
        verifyUpgrades();

        // Step 5: Verify immutables unchanged
        verifyImmutablePreservation();

        // Step 6: Verify access control preserved
        verifyAccessControlPreservation();

        // Step 7: Run fork tests (quick sanity checks)
        forkTests();

        console2.log("=== Upgrade Verification Complete ===");
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

        bytes32 timelockSalt = keccak256(abi.encode(targets, data, "reaudit-fixes-upgrade-v1", block.number));

        // Generate Gnosis Safe transaction JSON files
        console2.log("=== Generating Gnosis Safe Transaction JSONs ===");
        
        // Schedule transaction
        bytes memory scheduleCalldata = abi.encodeWithSelector(
            etherFiTimelock.scheduleBatch.selector,
            targets,
            values,
            data,
            bytes32(0), // predecessor
            timelockSalt,
            TIMELOCK_MIN_DELAY
        );
        writeSafeJson("script/upgrades/reaudit-fixes", "reaudit-fixes-upgrade_schedule.json", ETHERFI_UPGRADE_ADMIN, UPGRADE_TIMELOCK, 0, scheduleCalldata, 1);

        // Execute transaction
        bytes memory executeCalldata = abi.encodeWithSelector(
            etherFiTimelock.executeBatch.selector,
            targets,
            values,
            data,
            bytes32(0), // predecessor
            timelockSalt
        );
        writeSafeJson("script/upgrades/reaudit-fixes", "reaudit-fixes-upgrade_execute.json", ETHERFI_UPGRADE_ADMIN, UPGRADE_TIMELOCK, 0, executeCalldata, 1);
        
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
        WithdrawRequestNFT newWithdrawRequestNFTImplementation = new WithdrawRequestNFT(address(WITHDRAW_REQUEST_NFT_BUYBACK_SAFE));
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
    //------------------------------- IMMUTABLE SELECTOR DEFINITIONS -----------------------
    //--------------------------------------------------------------------------------------

    function getRedemptionManagerImmutableSelectors() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](7);
        selectors[0] = bytes4(keccak256("roleRegistry()"));
        selectors[1] = bytes4(keccak256("treasury()"));
        selectors[2] = bytes4(keccak256("eEth()"));
        selectors[3] = bytes4(keccak256("weEth()"));
        selectors[4] = bytes4(keccak256("liquidityPool()"));
        selectors[5] = bytes4(keccak256("etherFiRestaker()"));
        selectors[6] = bytes4(keccak256("lido()"));
    }

    function getRestakerImmutableSelectors() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](2);
        selectors[0] = bytes4(keccak256("rewardsCoordinator()"));
        selectors[1] = bytes4(keccak256("etherFiRedemptionManager()"));
    }

    function getRewardsRouterImmutableSelectors() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](3);
        selectors[0] = bytes4(keccak256("treasury()"));
        selectors[1] = bytes4(keccak256("liquidityPool()"));
        selectors[2] = bytes4(keccak256("roleRegistry()"));
    }

    function getWithdrawRequestNFTImmutableSelectors() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](1);
        selectors[0] = bytes4(keccak256("treasury()"));
    }

    // Note: Liquifier has no immutables

    //--------------------------------------------------------------------------------------
    //------------------------------- PRE-UPGRADE SNAPSHOTS --------------------------------
    //--------------------------------------------------------------------------------------
    function takePreUpgradeSnapshots() internal {
        console2.log("=== Taking Pre-Upgrade Snapshots ===");
        console2.log("");

        console2.log("--- Immutable Snapshots ---");
        preRedemptionManagerImmutables = takeImmutableSnapshot(
            ETHERFI_REDEMPTION_MANAGER,
            getRedemptionManagerImmutableSelectors()
        );
        console2.log("  EtherFiRedemptionManager: captured", preRedemptionManagerImmutables.selectors.length, "immutables");

        preRestakerImmutables = takeImmutableSnapshot(
            ETHERFI_RESTAKER,
            getRestakerImmutableSelectors()
        );
        console2.log("  EtherFiRestaker: captured", preRestakerImmutables.selectors.length, "immutables");

        preRewardsRouterImmutables = takeImmutableSnapshot(
            ETHERFI_REWARDS_ROUTER,
            getRewardsRouterImmutableSelectors()
        );
        console2.log("  EtherFiRewardsRouter: captured", preRewardsRouterImmutables.selectors.length, "immutables");

        preWithdrawRequestNFTImmutables = takeImmutableSnapshot(
            WITHDRAW_REQUEST_NFT,
            getWithdrawRequestNFTImmutableSelectors()
        );
        console2.log("  WithdrawRequestNFT: captured", preWithdrawRequestNFTImmutables.selectors.length, "immutables");

        console2.log("  Liquifier: no immutables to capture");

        // Access Control Snapshots
        console2.log("");
        console2.log("--- Access Control Snapshots ---");

        // Capture owners
        preRedemptionManagerOwner = _getOwner(ETHERFI_REDEMPTION_MANAGER);
        console2.log("  EtherFiRedemptionManager owner:", preRedemptionManagerOwner);

        preRestakerOwner = _getOwner(ETHERFI_RESTAKER);
        console2.log("  EtherFiRestaker owner:", preRestakerOwner);

        preRewardsRouterOwner = _getOwner(ETHERFI_REWARDS_ROUTER);
        console2.log("  EtherFiRewardsRouter owner:", preRewardsRouterOwner);

        preLiquifierOwner = _getOwner(LIQUIFIER);
        console2.log("  Liquifier owner:", preLiquifierOwner);

        preWithdrawRequestNFTOwner = _getOwner(WITHDRAW_REQUEST_NFT);
        console2.log("  WithdrawRequestNFT owner:", preWithdrawRequestNFTOwner);

        // Capture paused states
        preRedemptionManagerPaused = _getPaused(ETHERFI_REDEMPTION_MANAGER);
        console2.log("  EtherFiRedemptionManager paused:", preRedemptionManagerPaused);

        preLiquifierPaused = _getPaused(LIQUIFIER);
        console2.log("  Liquifier paused:", preLiquifierPaused);

        console2.log("");
        console2.log("Pre-upgrade snapshots captured!");
        console2.log("================================================");
        console2.log("");
    }

    //--------------------------------------------------------------------------------------
    //------------------------------- IMMUTABLE PRESERVATION VERIFICATION -----------------
    //--------------------------------------------------------------------------------------
    function verifyImmutablePreservation() internal view {
        console2.log("=== Verifying Immutable Preservation ===");
        console2.log("");

        ImmutableSnapshot memory postRedemptionManagerImmutables = takeImmutableSnapshot(
            ETHERFI_REDEMPTION_MANAGER,
            getRedemptionManagerImmutableSelectors()
        );
        verifyImmutablesUnchanged(preRedemptionManagerImmutables, postRedemptionManagerImmutables, "EtherFiRedemptionManager");

        ImmutableSnapshot memory postRestakerImmutables = takeImmutableSnapshot(
            ETHERFI_RESTAKER,
            getRestakerImmutableSelectors()
        );
        verifyImmutablesUnchanged(preRestakerImmutables, postRestakerImmutables, "EtherFiRestaker");

        ImmutableSnapshot memory postRewardsRouterImmutables = takeImmutableSnapshot(
            ETHERFI_REWARDS_ROUTER,
            getRewardsRouterImmutableSelectors()
        );
        verifyImmutablesUnchanged(preRewardsRouterImmutables, postRewardsRouterImmutables, "EtherFiRewardsRouter");

        ImmutableSnapshot memory postWithdrawRequestNFTImmutables = takeImmutableSnapshot(
            WITHDRAW_REQUEST_NFT,
            getWithdrawRequestNFTImmutableSelectors()
        );
        verifyImmutablesUnchanged(preWithdrawRequestNFTImmutables, postWithdrawRequestNFTImmutables, "WithdrawRequestNFT");

        console2.log("  Liquifier: no immutables to verify");

        console2.log("");
        console2.log("All immutable preservation checks passed!");
        console2.log("================================================");
        console2.log("");
    }

    //--------------------------------------------------------------------------------------
    //------------------------------- ACCESS CONTROL PRESERVATION --------------------------
    //--------------------------------------------------------------------------------------
    function verifyAccessControlPreservation() internal view {
        console2.log("=== Verifying Access Control Preservation ===");
        console2.log("");

        console2.log("--- Owner Verification ---");

        address postRedemptionManagerOwner = _getOwner(ETHERFI_REDEMPTION_MANAGER);
        require(postRedemptionManagerOwner == preRedemptionManagerOwner, "EtherFiRedemptionManager: owner changed");
        console2.log("[OWNER OK] EtherFiRedemptionManager:", postRedemptionManagerOwner);

        address postRestakerOwner = _getOwner(ETHERFI_RESTAKER);
        require(postRestakerOwner == preRestakerOwner, "EtherFiRestaker: owner changed");
        console2.log("[OWNER OK] EtherFiRestaker:", postRestakerOwner);

        address postRewardsRouterOwner = _getOwner(ETHERFI_REWARDS_ROUTER);
        require(postRewardsRouterOwner == preRewardsRouterOwner, "EtherFiRewardsRouter: owner changed");
        console2.log("[OWNER OK] EtherFiRewardsRouter:", postRewardsRouterOwner);

        address postLiquifierOwner = _getOwner(LIQUIFIER);
        require(postLiquifierOwner == preLiquifierOwner, "Liquifier: owner changed");
        console2.log("[OWNER OK] Liquifier:", postLiquifierOwner);

        address postWithdrawRequestNFTOwner = _getOwner(WITHDRAW_REQUEST_NFT);
        require(postWithdrawRequestNFTOwner == preWithdrawRequestNFTOwner, "WithdrawRequestNFT: owner changed");
        console2.log("[OWNER OK] WithdrawRequestNFT:", postWithdrawRequestNFTOwner);

        // --- Paused State Verification ---
        console2.log("");
        console2.log("--- Paused State Verification ---");

        bool postRedemptionManagerPaused = _getPaused(ETHERFI_REDEMPTION_MANAGER);
        require(postRedemptionManagerPaused == preRedemptionManagerPaused, "EtherFiRedemptionManager: paused state changed");
        console2.log("[PAUSED OK] EtherFiRedemptionManager:", postRedemptionManagerPaused);

        bool postLiquifierPaused = _getPaused(LIQUIFIER);
        require(postLiquifierPaused == preLiquifierPaused, "Liquifier: paused state changed");
        console2.log("[PAUSED OK] Liquifier:", postLiquifierPaused);

        // --- Initialization State Verification ---
        console2.log("");
        console2.log("--- Initialization State Verification ---");

        verifyNotReinitializable(ETHERFI_REDEMPTION_MANAGER, "EtherFiRedemptionManager");
        verifyNotReinitializable(ETHERFI_RESTAKER, "EtherFiRestaker");
        verifyNotReinitializable(ETHERFI_REWARDS_ROUTER, "EtherFiRewardsRouter");
        verifyNotReinitializable(LIQUIFIER, "Liquifier");
        verifyNotReinitializable(WITHDRAW_REQUEST_NFT, "WithdrawRequestNFT");

        console2.log("");
        console2.log("All access control preservation checks passed!");
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

        // Quick sanity checks
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
