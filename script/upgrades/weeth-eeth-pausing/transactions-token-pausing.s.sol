// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "forge-std/Script.sol";
import "forge-std/console2.sol";
import {Utils, ICreate2Factory} from "../../utils/utils.sol";
import {EtherFiTimelock} from "../../../src/EtherFiTimelock.sol";
import {RoleRegistry} from "../../../src/RoleRegistry.sol";
import {EETH as EETHContract} from "../../../src/EETH.sol";
import {WeETH as WeETHContract} from "../../../src/WeETH.sol";
import {MembershipManager} from "../../../src/MembershipManager.sol";
import {MembershipNFT} from "../../../src/MembershipNFT.sol";
import "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import {ContractCodeChecker} from "../../../script/ContractCodeChecker.sol";

/**
 * @title TokenPausingTransactions
 * @notice Schedules and executes upgrades for token pausing
 * @dev Run with: forge script script/upgrades/weeth-eeth-pausing/transactions-token-pausing.s.sol --fork-url $MAINNET_RPC_URL
 * 
 * Changes being upgraded:
 * - WeETH: Pausing functionality
 * - EETH: Pausing functionality
 * - MembershipManager: Pausing functionality for NFTs
 * - MembershipNFT: Pausing functionality for NFTs
 */
contract TokenPausingTransactions is Utils {
    EtherFiTimelock etherFiTimelock = EtherFiTimelock(payable(UPGRADE_TIMELOCK));
    ContractCodeChecker contractCodeChecker;
    uint256 constant TIMELOCK_MIN_DELAY = 864000; // 10 days

    //--------------------------------------------------------------------------------------
    //---------------------------- NEW IMPLEMENTATION ADDRESSES ----------------------------
    //--------------------------------------------------------------------------------------
    address constant eETHImpl = 0xA91F8a52F0C1b4D3fDC256fC5bEBCA4D627da392;
    address constant weETHImpl = 0xb4fed2BF48EF08b93256AE67ad3bFaB6F1f5c13a;
    address constant membershipManagerImpl = 0x9D795b303B9dA3488FD3A4ca4702c872576BD0c6;
    address constant membershipNFTImpl = 0x408de8D339F40086c5643EE4778E0F872aB5E423;

    //--------------------------------------------------------------------------------------
    //---------------------------- PAUSER ROLE ADDRESSES  ----------------------------------
    //--------------------------------------------------------------------------------------

    address constant EETH_PAUSER = 0x5B38Da6a701c568545dCfcB03FcB875f56beddC4;
    address constant WEETH_PAUSER = 0x5B38Da6a701c568545dCfcB03FcB875f56beddC4;
    address constant EETH_PAUSER_UNTIL = 0x5B38Da6a701c568545dCfcB03FcB875f56beddC4;
    address constant WEETH_PAUSER_UNTIL = 0x5B38Da6a701c568545dCfcB03FcB875f56beddC4;

    //--------------------------------------------------------------------------------------
    //---------------------------- IMMUTABLE SNAPSHOTS (PRE-UPGRADE) -----------------------
    //--------------------------------------------------------------------------------------
    ImmutableSnapshot internal preEETHImmutables;
    ImmutableSnapshot internal preWeETHImmutables;

    //--------------------------------------------------------------------------------------
    //---------------------------- ACCESS CONTROL SNAPSHOTS (PRE-UPGRADE) ------------------
    //--------------------------------------------------------------------------------------
    address internal preEETHOwner;
    address internal preWeETHOwner;
    address internal preMembershipManagerOwner;
    address internal preMembershipNFTOwner;

    bool internal preMembershipManagerPaused;

    // Salt used for CREATE2 deployment
    bytes32 constant commitHashSalt = bytes32(bytes20(hex"0b0b98b174770750ef716029f080f660c9623500"));

    function run() public {
        console2.log("================================================");
        console2.log("====== Token Pausing Upgrade Transactions ======");
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

        // Build upgrade batch (4 upgrades total + 4 role grants)
        address[] memory targets = new address[](8);
        bytes[] memory data = new bytes[](targets.length);
        uint256[] memory values = new uint256[](targets.length); // Default to 0

        //--------------------------------------------------------------------------------------
        //------------------------------- CONTRACT UPGRADES  -----------------------------------
        //--------------------------------------------------------------------------------------

        // 1. EETH (UUPS)
        targets[0] = EETH;
        data[0] = abi.encodeWithSelector(UUPSUpgradeable.upgradeTo.selector, eETHImpl);

        // 2. WeETH (UUPS)
        targets[1] = WEETH;
        data[1] = abi.encodeWithSelector(UUPSUpgradeable.upgradeTo.selector, weETHImpl);

        // 3. MembershipManager (UUPS)
        targets[2] = MEMBERSHIP_MANAGER;
        data[2] = abi.encodeWithSelector(UUPSUpgradeable.upgradeTo.selector, membershipManagerImpl);

        // 4. MembershipNFT (UUPS)
        targets[3] = MEMBERSHIP_NFT;
        data[3] = abi.encodeWithSelector(UUPSUpgradeable.upgradeTo.selector, membershipNFTImpl);

        // 5. Grant EETH_PAUSER_ROLE to EETH_PAUSER
        targets[4] = ROLE_REGISTRY;
        data[4] = abi.encodeWithSelector(RoleRegistry.grantRole.selector, EETHContract(eETHImpl).EETH_PAUSER_ROLE(), EETH_PAUSER);

        // 6. Grant WEETH_PAUSER_ROLE to WEETH_PAUSER
        targets[5] = ROLE_REGISTRY;
        data[5] = abi.encodeWithSelector(RoleRegistry.grantRole.selector, WeETHContract(weETHImpl).WEETH_PAUSER_ROLE(), WEETH_PAUSER);

        // 7. Grant EETH_PAUSER_UNTIL_ROLE to EETH_PAUSER_UNTIL
        targets[6] = ROLE_REGISTRY;
        data[6] = abi.encodeWithSelector(RoleRegistry.grantRole.selector, EETHContract(eETHImpl).EETH_PAUSER_UNTIL_ROLE(), EETH_PAUSER_UNTIL);
        
        // 8. Grant WEETH_PAUSER_UNTIL_ROLE to WEETH_PAUSER_UNTIL
        targets[7] = ROLE_REGISTRY;
        data[7] = abi.encodeWithSelector(RoleRegistry.grantRole.selector, WeETHContract(weETHImpl).WEETH_PAUSER_UNTIL_ROLE(), WEETH_PAUSER_UNTIL);

        bytes32 timelockSalt = keccak256(abi.encode(targets, data, "weeth-eeth-pausing-upgrade", block.number));

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
        writeSafeJson("script/upgrades/weeth-eeth-pausing", "weeth-eeth-pausing-upgrade_schedule.json", ETHERFI_UPGRADE_ADMIN, UPGRADE_TIMELOCK, 0, scheduleCalldata, 1);

        // Execute transaction
        bytes memory executeCalldata = abi.encodeWithSelector(
            etherFiTimelock.executeBatch.selector,
            targets,
            values,
            data,
            bytes32(0), // predecessor
            timelockSalt
        );
        writeSafeJson("script/upgrades/weeth-eeth-pausing", "weeth-eeth-pausing-upgrade_execute.json", ETHERFI_UPGRADE_ADMIN, UPGRADE_TIMELOCK, 0, executeCalldata, 1);
        
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

        EETHContract newEETHImplementation = new EETHContract(ROLE_REGISTRY, LIQUIDITY_POOL);
        WeETHContract newWeETHImplementation = new WeETHContract(EETH, LIQUIDITY_POOL, ROLE_REGISTRY);
        MembershipManager newMembershipManagerImplementation = new MembershipManager();
        MembershipNFT newMembershipNFTImplementation = new MembershipNFT(EETH);

        contractCodeChecker.verifyContractByteCodeMatch(eETHImpl, address(newEETHImplementation));
        contractCodeChecker.verifyContractByteCodeMatch(weETHImpl, address(newWeETHImplementation));
        contractCodeChecker.verifyContractByteCodeMatch(membershipManagerImpl, address(newMembershipManagerImplementation));
        contractCodeChecker.verifyContractByteCodeMatch(membershipNFTImpl, address(newMembershipNFTImplementation));

        console2.log("");
        console2.log("All bytecode verifications passed!");
        console2.log("================================================");
        console2.log("");
    }

    //--------------------------------------------------------------------------------------
    //------------------------------- IMMUTABLE SELECTOR DEFINITIONS -----------------------
    //--------------------------------------------------------------------------------------

    function getEETHImmutableSelectors() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](1);
        selectors[0] = bytes4(keccak256("roleRegistry()"));
    }

    function getWeETHImmutableSelectors() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](1);
        selectors[0] = bytes4(keccak256("roleRegistry()"));
    }

    // Note: MembershipManager has no immutables

    // Note: MembershipNFT has no pre-upgrade immutables

    //--------------------------------------------------------------------------------------
    //------------------------------- PRE-UPGRADE SNAPSHOTS --------------------------------
    //--------------------------------------------------------------------------------------
    function takePreUpgradeSnapshots() internal {
        console2.log("=== Taking Pre-Upgrade Snapshots ===");
        console2.log("");

        console2.log("--- Immutable Snapshots ---");
        preEETHImmutables = takeImmutableSnapshot(
            EETH,
            getEETHImmutableSelectors()
        );
        console2.log("  EETH: captured", preEETHImmutables.selectors.length, "immutables");

        preWeETHImmutables = takeImmutableSnapshot(
            WEETH,
            getWeETHImmutableSelectors()
        );
        console2.log("  WeETH: captured", preWeETHImmutables.selectors.length, "immutables");

        console2.log("  MembershipManager: no immutables to capture");

        console2.log("  MembershipNFT: no immutables to capture");

        // Access Control Snapshots
        console2.log("");
        console2.log("--- Access Control Snapshots ---");

        // Capture owners
        preEETHOwner = _getOwner(EETH);
        console2.log("  EETH owner:", preEETHOwner);

        preWeETHOwner = _getOwner(WEETH);
        console2.log("  WeETH owner:", preWeETHOwner);

        preMembershipManagerOwner = _getOwner(MEMBERSHIP_MANAGER);
        console2.log("  MembershipManager owner:", preMembershipManagerOwner);

        preMembershipNFTOwner = _getOwner(MEMBERSHIP_NFT);
        console2.log("  MembershipNFT owner:", preMembershipNFTOwner);

        // Capture paused states
        preMembershipManagerPaused = _getPaused(MEMBERSHIP_MANAGER);
        console2.log("  MembershipManager paused:", preMembershipManagerPaused);

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

        ImmutableSnapshot memory postEETHImmutables = takeImmutableSnapshot(
            EETH,
            getEETHImmutableSelectors()
        );
        verifyImmutablesUnchanged(preEETHImmutables, postEETHImmutables, "EETH");

        ImmutableSnapshot memory postWeETHImmutables = takeImmutableSnapshot(
            WEETH,
            getWeETHImmutableSelectors()
        );
        verifyImmutablesUnchanged(preWeETHImmutables, postWeETHImmutables, "WeETH");

        console2.log("  MembershipManager: no immutables to verify");

        console2.log("  MembershipNFT: no immutables to verify");

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

        address postEETHOwner = _getOwner(EETH);
        require(postEETHOwner == preEETHOwner, "EETH: owner changed");
        console2.log("[OWNER OK] EETH:", postEETHOwner);

        address postWeETHOwner = _getOwner(WEETH);
        require(postWeETHOwner == preWeETHOwner, "WeETH: owner changed");
        console2.log("[OWNER OK] WeETH:", postWeETHOwner);

        address postMembershipManagerOwner = _getOwner(MEMBERSHIP_MANAGER);
        require(postMembershipManagerOwner == preMembershipManagerOwner, "MembershipManager: owner changed");
        console2.log("[OWNER OK] MembershipManager:", postMembershipManagerOwner);

        address postMembershipNFTOwner = _getOwner(MEMBERSHIP_NFT);
        require(postMembershipNFTOwner == preMembershipNFTOwner, "MembershipNFT: owner changed");
        console2.log("[OWNER OK] MembershipNFT:", postMembershipNFTOwner);

        // --- Paused State Verification ---
        console2.log("");
        console2.log("--- Paused State Verification ---");

        bool postMembershipManagerPaused = _getPaused(MEMBERSHIP_MANAGER);
        require(postMembershipManagerPaused == preMembershipManagerPaused, "MembershipManager: paused state changed");
        console2.log("[PAUSED OK] MembershipManager:", postMembershipManagerPaused);

        // --- Initialization State Verification ---
        console2.log("");
        console2.log("--- Initialization State Verification ---");

        verifyNotReinitializable(EETH, "EETH");
        verifyNotReinitializable(WEETH, "WeETH");
        verifyNotReinitializable(MEMBERSHIP_MANAGER, "MembershipManager");
        verifyNotReinitializable(MEMBERSHIP_NFT, "MembershipNFT");

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

        // 1. EETH
        {
            address currentImpl = getImplementation(EETH);
            require(currentImpl == eETHImpl, "EETH upgrade failed");
            console2.log("EETH implementation:", currentImpl);
        }

        // 2. WeETH
        {
            address currentImpl = getImplementation(WEETH);
            require(currentImpl == weETHImpl, "WeETH upgrade failed");
            console2.log("WeETH implementation:", currentImpl);
        }

        // 3. MembershipManager
        {
            address currentImpl = getImplementation(MEMBERSHIP_MANAGER);
            require(currentImpl == membershipManagerImpl, "MembershipManager upgrade failed");
            console2.log("MembershipManager implementation:", currentImpl);
        }

        // 4. MembershipNFT
        {
            address currentImpl = getImplementation(MEMBERSHIP_NFT);
            require(currentImpl == membershipNFTImpl, "MembershipNFT upgrade failed");
            console2.log("MembershipNFT implementation:", currentImpl);
        }

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
        testEETHPauseFunctionality();
        testWeETHPauseFunctionality();

        console2.log("");
        console2.log("All fork tests passed!");
        console2.log("================================================");
        console2.log("");
    }

    function testEETHPauseFunctionality() internal {
        console2.log("Testing EETH pause functionality...");

        address alice = makeAddr("alice");
        address bob = makeAddr("bob");
        
        EETHContract eETH = EETHContract(payable(EETH));
        require(!eETH.paused(), "EETH: should not be paused");

        vm.prank(EETH_PAUSER);
        eETH.pause();
        require(eETH.paused(), "EETH: should be paused");

        vm.expectRevert("PAUSED");
        eETH.transfer(alice, 1 ether);

        vm.prank(alice);
        eETH.approve(bob, 1 ether);
        vm.prank(bob);
        vm.expectRevert("PAUSED");
        eETH.transferFrom(alice, bob, 1 ether);

        vm.prank(LIQUIDITY_POOL);
        vm.expectRevert("MINT PAUSED");
        eETH.mintShares(alice, 1 ether);

        vm.prank(LIQUIDITY_POOL);
        vm.expectRevert("BURN PAUSED");
        eETH.burnShares(alice, 1 ether);

        vm.prank(EETH_PAUSER);
        eETH.unpause();
        require(!eETH.paused(), "EETH: should not be paused");

        require(!eETH.isPausedUntil(alice), "Alice should not be paused until");

        vm.prank(EETH_PAUSER_UNTIL);
        eETH.pauseUntil(alice);
        require(eETH.isPausedUntil(alice), "Alice should be paused until");

        vm.prank(alice);
        vm.expectRevert("SENDER PAUSED");
        eETH.transfer(bob, 1 ether);

        vm.expectRevert("RECIPIENT PAUSED");
        eETH.transfer(alice, 1 ether);

        vm.prank(alice);
        eETH.approve(bob, 1 ether);
        vm.prank(bob);
        vm.expectRevert("SENDER PAUSED");
        eETH.transferFrom(alice, bob, 1 ether);

        vm.prank(bob);
        eETH.approve(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert("RECIPIENT PAUSED");
        eETH.transferFrom(bob, alice, 1 ether);

        vm.prank(LIQUIDITY_POOL);
        vm.expectRevert("MINT PAUSED");
        eETH.mintShares(alice, 1 ether);

        vm.prank(LIQUIDITY_POOL);
        vm.expectRevert("BURN PAUSED");
        eETH.burnShares(alice, 1 ether);

        vm.prank(EETH_PAUSER);
        eETH.cancelPauseUntil(alice);
        require(!eETH.isPausedUntil(alice), "Alice should not be paused until");

        vm.prank(EETH_PAUSER);
        eETH.extendPauseUntil(alice, 1 days);
        require(!eETH.isPausedUntil(alice), "Alice should NOT be paused until as she was already not paused until");

        vm.prank(EETH_PAUSER_UNTIL);
        eETH.pauseUntil(alice);
        require(eETH.isPausedUntil(alice), "Alice should be paused until");
        vm.warp(block.timestamp + 1 days + 1);
        require(!eETH.isPausedUntil(alice), "Alice should NOT be paused until as it expired");

        vm.prank(EETH_PAUSER_UNTIL);
        eETH.pauseUntil(alice);
        uint256 pauseUntil = eETH.pausedUntil(alice);
        vm.prank(EETH_PAUSER);
        eETH.extendPauseUntil(alice, 2 days);
        require(eETH.pausedUntil(alice) > pauseUntil, "Alice should be paused until for longer");
        
        console2.log("  EETH pause functionality check passed");
    }

    function testWeETHPauseFunctionality() internal {
        console2.log("Testing WeETH pause functionality...");

        address alice = makeAddr("alice");
        address bob = makeAddr("bob");
        
        WeETHContract weETH = WeETHContract(payable(WEETH));
        require(!weETH.paused(), "WeETH: should not be paused");

        vm.prank(WEETH_PAUSER);
        weETH.pause();
        require(weETH.paused(), "WeETH: should be paused");

        vm.expectRevert("PAUSED");
        weETH.transfer(alice, 1 ether);

        vm.prank(alice);
        weETH.approve(bob, 1 ether);
        vm.prank(bob);
        vm.expectRevert("PAUSED");
        weETH.transferFrom(alice, bob, 1 ether);

        vm.prank(alice);
        vm.expectRevert("RECIPIENT PAUSED");
        weETH.wrap(1 ether);

        vm.prank(alice);
        vm.expectRevert("SENDER PAUSED");
        weETH.unwrap(1 ether);

        vm.prank(WEETH_PAUSER);
        weETH.unpause();
        require(!weETH.paused(), "WeETH: should not be paused");

        require(!weETH.isPausedUntil(alice), "Alice should not be paused until");

        vm.prank(WEETH_PAUSER_UNTIL);
        weETH.pauseUntil(alice);
        require(weETH.isPausedUntil(alice), "Alice should be paused until");

        vm.prank(alice);
        vm.expectRevert("SENDER PAUSED");
        weETH.transfer(bob, 1 ether);

        vm.expectRevert("RECIPIENT PAUSED");
        weETH.transfer(alice, 1 ether);

        vm.prank(alice);
        weETH.approve(bob, 1 ether);
        vm.prank(bob);
        vm.expectRevert("SENDER PAUSED");
        weETH.transferFrom(alice, bob, 1 ether);

        vm.prank(bob);
        weETH.approve(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert("RECIPIENT PAUSED");
        weETH.transferFrom(bob, alice, 1 ether);

        vm.prank(alice);
        vm.expectRevert("RECIPIENT PAUSED");
        weETH.wrap(1 ether);

        vm.prank(alice);
        vm.expectRevert("SENDER PAUSED");
        weETH.unwrap(1 ether);

        vm.prank(WEETH_PAUSER);
        weETH.cancelPauseUntil(alice);
        require(!weETH.isPausedUntil(alice), "Alice should not be paused until");

        vm.prank(WEETH_PAUSER);
        weETH.extendPauseUntil(alice, 1 days);
        require(!weETH.isPausedUntil(alice), "Alice should NOT be paused until as she was already not paused until");

        vm.prank(WEETH_PAUSER_UNTIL);
        weETH.pauseUntil(alice);
        require(weETH.isPausedUntil(alice), "Alice should be paused until");
        vm.warp(block.timestamp + 1 days + 1);
        require(!weETH.isPausedUntil(alice), "Alice should NOT be paused until as it expired");

        vm.prank(WEETH_PAUSER_UNTIL);
        weETH.pauseUntil(alice);
        uint256 pauseUntil = weETH.pausedUntil(alice);
        vm.prank(WEETH_PAUSER);
        weETH.extendPauseUntil(alice, 2 days);
        require(weETH.pausedUntil(alice) > pauseUntil, "Alice should be paused until for longer");
        
        console2.log("  WeETH pause functionality check passed");
    }
}
