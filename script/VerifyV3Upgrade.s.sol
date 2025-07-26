// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "forge-std/Script.sol";
import "forge-std/console2.sol";
import "../src/interfaces/IStakingManager.sol";
import "../src/interfaces/IEtherFiNodesManager.sol";
import "../src/interfaces/IEtherFiNode.sol";
import "../src/interfaces/ILiquidityPool.sol";
import "../src/interfaces/IEtherFiOracle.sol";
import "../src/interfaces/IEtherFiAdmin.sol";
import "../src/interfaces/IeETH.sol";
import "../src/interfaces/IWeETH.sol";
import "../src/interfaces/ITNFT.sol";
import "../src/StakingManager.sol";
import "../src/EtherFiNodesManager.sol";
import "../src/EtherFiNode.sol";
import "../src/LiquidityPool.sol";
import "../src/AuctionManager.sol";
import "../src/RoleRegistry.sol";
import "../lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";

interface IUpgrade {
    function upgradeTo(address) external;

    function roleRegistry() external returns (address);
}

contract VerifyV3Upgrade is Script {
    // Mainnet addresses
    StakingManager stakingManager =
        StakingManager(0x25e821b7197B146F7713C3b89B6A4D83516B912d);
    ILiquidityPool liquidityPool =
        ILiquidityPool(0x308861A430be4cce5502d0A12724771Fc6DaF216);
    EtherFiNodesManager etherFiNodesManager =
        EtherFiNodesManager(
            payable(0x8B71140AD2e5d1E7018d2a7f8a288BD3CD38916F)
        );
    AuctionManager auctionManager =
        AuctionManager(0x00C452aFFee3a17d9Cecc1Bcd2B8d5C7635C4CB9);
    RoleRegistry roleRegistry =
        RoleRegistry(0x62247D29B4B9BECf4BB73E0c722cf6445cfC7cE9);

    // Additional contract addresses to verify
    address etherFiOracle = 0x57AaF0004C716388B21795431CD7D5f9D3Bb6a41;
    address etherFiAdmin = 0x0EF8fa4760Db8f5Cd4d993f3e3416f30f942D705;
    address eETH = 0x35fA164735182de50811E8e2E824cFb9B6118ac2;
    address weETH = 0xCd5fE23C85820F7B72D0926FC9b05b43E359b7ee;
    address TNFT = 0x7B5ae07E2AF1C861BcC4736D23f5f66A61E0cA5e;

    // ERC1967 storage slot for implementation address
    bytes32 constant IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    // Track verification results
    uint256 totalChecks;
    uint256 passedChecks;
    bool allChecksPassed = true;

    function run() public {
        //Select RPC to fork
        string memory rpc = vm.rpcUrl(vm.envString("TENDERLY_TEST_RPC"));
        vm.createSelectFork(rpc);

        console2.log("========================================");
        console2.log("Starting V3 Upgrade Verification");
        console2.log("========================================\n");

        // 1. Verify Role Registry Configuration
        console2.log("1. VERIFYING ROLE REGISTRY CONFIGURATION");
        console2.log("----------------------------------------");
        verifyRoleRegistryConfiguration();

        // 2. Verify Contract Upgradeability
        console2.log("\n2. VERIFYING CONTRACT UPGRADEABILITY");
        console2.log("----------------------------------------");
        verifyUpgradeability();

        // 3. Verify Role Assignments
        console2.log("\n3. VERIFYING ROLE ASSIGNMENTS");
        console2.log("----------------------------------------");
        verifyRoleAssignments();

        // 4. Verify Contract Interactions
        console2.log("\n4. VERIFYING CONTRACT INTERACTIONS");
        console2.log("----------------------------------------");
        verifyContractInteractions();

        // 5. Verify Additional Contracts (Oracle, Admin, eETH, weETH, TNFT)
        console2.log("\n5. VERIFYING ADDITIONAL CONTRACTS");
        console2.log("----------------------------------------");
        verifyAdditionalContracts();

        // Summary
        console2.log("\n========================================");
        console2.log("VERIFICATION SUMMARY");
        console2.log("========================================");
        console2.log("Total Checks:", totalChecks);
        console2.log("Passed:", passedChecks);
        console2.log("Failed:", totalChecks - passedChecks);

        if (allChecksPassed) {
            console2.log("\x1b[32m\n[PASS] ALL VERIFICATIONS PASSED!\x1b[0m");
        } else {
            console2.log("\x1b[31m\n[FAIL] SOME VERIFICATIONS FAILED!\x1b[0m");
            revert("Verification failed");
        }
    }

    function verifyRoleRegistryConfiguration() internal {
        // Check StakingManager has correct RoleRegistry
        console2.log("Checking StakingManager RoleRegistry...");
        checkCondition(
            address(stakingManager.roleRegistry()) == address(roleRegistry),
            "StakingManager has correct RoleRegistry"
        );

        // Check EtherFiNodesManager has correct RoleRegistry
        console2.log("Checking EtherFiNodesManager RoleRegistry...");
        checkCondition(
            address(etherFiNodesManager.roleRegistry()) ==
                address(roleRegistry),
            "EtherFiNodesManager has correct RoleRegistry"
        );

        // Check a sample EtherFiNode implementation has correct RoleRegistry
        console2.log("Checking EtherFiNode implementation RoleRegistry...");
        address beacon = stakingManager.getEtherFiNodeBeacon();
        address etherFiNodeImpl = getImplementation(beacon);
        if (etherFiNodeImpl != address(0)) {
            // Create a temporary instance to check the roleRegistry
            EtherFiNode nodeImpl = EtherFiNode(payable(etherFiNodeImpl));
            checkCondition(
                address(nodeImpl.roleRegistry()) == address(roleRegistry),
                "EtherFiNode implementation has correct RoleRegistry"
            );
        }

        // Check LiquidityPool has correct RoleRegistry
        console2.log("Checking LiquidityPool RoleRegistry...");
        checkCondition(
            address(IUpgrade(address(liquidityPool)).roleRegistry()) ==
                address(roleRegistry),
            "LiquidityPool has correct RoleRegistry"
        );

        // AuctionManager does not have RoleRegistry

        // Check eETH has correct RoleRegistry
        console2.log("Checking eETH RoleRegistry...");
        checkCondition(
            address(IUpgrade(eETH).roleRegistry()) == address(roleRegistry),
            "eETH has correct RoleRegistry"
        );

        // Check weETH has correct RoleRegistry
        console2.log("Checking weETH RoleRegistry...");
        checkCondition(
            address(IUpgrade(weETH).roleRegistry()) == address(roleRegistry),
            "weETH has correct RoleRegistry"
        );

        //EtherFiOracle does not have RoleRegistry

        // Check EtherFiAdmin has correct RoleRegistry
        console2.log("Checking EtherFiAdmin RoleRegistry...");
        checkCondition(
            address(IUpgrade(etherFiAdmin).roleRegistry()) ==
                address(roleRegistry),
            "EtherFiAdmin has correct RoleRegistry"
        );
    }

    function verifyUpgradeability() internal {
        // ────────────────────────────────────────────────────────────────────────────
        // Individual proxy checks
        // ────────────────────────────────────────────────────────────────────────────
        verifyProxyUpgradeability(address(stakingManager), "StakingManager");
        verifyProxyUpgradeability(
            address(etherFiNodesManager),
            "EtherFiNodesManager"
        );
        verifyProxyUpgradeability(address(liquidityPool), "LiquidityPool");
        verifyProxyUpgradeability(address(auctionManager), "AuctionManager");

        // ────────────────────────────────────────────────────────────────────────────
        // Permission check – only the protocol upgrader can upgrade
        // ────────────────────────────────────────────────────────────────────────────
        console2.log("Checking upgrade permissions...");
        address protocolUpgrader = roleRegistry.owner();
        checkCondition(
            protocolUpgrader != address(0),
            "Protocol upgrader (RoleRegistry owner) is set"
        );
        try roleRegistry.onlyProtocolUpgrader(protocolUpgrader) {
            checkCondition(true, "Protocol upgrader is owner");
        } catch {
            checkCondition(false, "Protocol upgrader is not owner");
        }

        // Pretend to be someone *else* and make sure the upgrade reverts
        address random = address(0xBEEF);
        vm.startPrank(random);
        bytes memory payload = abi.encodeWithSignature(
            "upgradeTo(address)",
            protocolUpgrader
        ); // any addr
        (bool success, ) = address(stakingManager).call(payload);
        vm.stopPrank();

        checkCondition(
            !success,
            "Only protocol upgrader can execute upgradeTo()"
        );
        address currentImpl = getImplementation(address(stakingManager));

        vm.startPrank(protocolUpgrader);
        payload = abi.encodeWithSignature("upgradeTo(address)", currentImpl); // any addr
        (success, ) = address(stakingManager).call(payload);
        vm.stopPrank();

        checkCondition(success, "Protocol upgrader can execute upgradeTo()");
    }

    function verifyProxyUpgradeability(
        address proxy,
        string memory name
    ) internal {
        console2.log(string.concat("Checking ", name, " upgradeability..."));

        // 1. Proxy really points to an implementation
        address impl = getImplementation(proxy);
        console.log("Implementation:", impl);
        checkCondition(
            impl != address(0) && impl != proxy,
            string.concat(name, " is a proxy with an implementation")
        );

        // 2. Implementation exposes correct proxiableUUID()
        try IERC1822ProxiableUpgradeable(impl).proxiableUUID() returns (
            bytes32 slot
        ) {
            checkCondition(
                slot == IMPLEMENTATION_SLOT,
                string.concat(name, " implementation returns correct UUID")
            );
        } catch {
            checkCondition(
                false,
                string.concat(name, " implementation missing proxiableUUID()")
            );
        }

        (bool ok, bytes memory data) = proxy.staticcall(
            abi.encodeWithSignature("upgradeTo(address)", impl)
        );

        checkCondition(
            ok || data.length != 0,
            string.concat(name, " proxy exposes upgradeTo()")
        );
        vm.prank(address(0xcaffe));
        try IUpgrade(proxy).upgradeTo(address(0xbeef)) {
            checkCondition(
                false,
                string.concat(name, " allows a random to upgrade")
            );
        } catch {
            checkCondition(
                true,
                string.concat(name, " does not allows a random to upgrade")
            );
        }
    }

    function verifyRoleAssignments() internal {
        // Define expected roles based on prelude.t.sol

        // StakingManager roles
        bytes32 STAKING_MANAGER_NODE_CREATOR_ROLE = keccak256(
            "STAKING_MANAGER_NODE_CREATOR_ROLE"
        );
        console2.log("Checking StakingManager roles...");

        // At least check that the role exists in the system
        checkCondition(
            STAKING_MANAGER_NODE_CREATOR_ROLE ==
                stakingManager.STAKING_MANAGER_NODE_CREATOR_ROLE(),
            "STAKING_MANAGER_NODE_CREATOR_ROLE constant matches"
        );

        // EtherFiNodesManager roles
        bytes32 ETHERFI_NODES_MANAGER_ADMIN_ROLE = keccak256(
            "ETHERFI_NODES_MANAGER_ADMIN_ROLE"
        );
        bytes32 ETHERFI_NODES_MANAGER_EIGENLAYER_ADMIN_ROLE = keccak256(
            "ETHERFI_NODES_MANAGER_EIGENLAYER_ADMIN_ROLE"
        );
        bytes32 ETHERFI_NODES_MANAGER_CALL_FORWARDER_ROLE = keccak256(
            "ETHERFI_NODES_MANAGER_CALL_FORWARDER_ROLE"
        );

        console2.log("Checking EtherFiNodesManager roles...");
        checkCondition(
            ETHERFI_NODES_MANAGER_ADMIN_ROLE ==
                etherFiNodesManager.ETHERFI_NODES_MANAGER_ADMIN_ROLE(),
            "ETHERFI_NODES_MANAGER_ADMIN_ROLE constant matches"
        );
        checkCondition(
            ETHERFI_NODES_MANAGER_EIGENLAYER_ADMIN_ROLE ==
                etherFiNodesManager
                    .ETHERFI_NODES_MANAGER_EIGENLAYER_ADMIN_ROLE(),
            "ETHERFI_NODES_MANAGER_EIGENLAYER_ADMIN_ROLE constant matches"
        );
        checkCondition(
            ETHERFI_NODES_MANAGER_CALL_FORWARDER_ROLE ==
                etherFiNodesManager.ETHERFI_NODES_MANAGER_CALL_FORWARDER_ROLE(),
            "ETHERFI_NODES_MANAGER_CALL_FORWARDER_ROLE constant matches"
        );

        // Check protocol pauser/unpauser roles exist
        bytes32 PROTOCOL_PAUSER = keccak256("PROTOCOL_PAUSER");
        bytes32 PROTOCOL_UNPAUSER = keccak256("PROTOCOL_UNPAUSER");

        console2.log("Checking protocol pause roles...");
        checkCondition(
            PROTOCOL_PAUSER == roleRegistry.PROTOCOL_PAUSER(),
            "PROTOCOL_PAUSER constant matches"
        );
        checkCondition(
            PROTOCOL_UNPAUSER == roleRegistry.PROTOCOL_UNPAUSER(),
            "PROTOCOL_UNPAUSER constant matches"
        );
    }

    function verifyContractInteractions() internal {
        // Verify StakingManager knows about other contracts
        console2.log("Checking StakingManager contract references...");
        checkCondition(
            address(stakingManager.liquidityPool()) == address(liquidityPool),
            "StakingManager has correct LiquidityPool reference"
        );
        checkCondition(
            address(stakingManager.etherFiNodesManager()) ==
                address(etherFiNodesManager),
            "StakingManager has correct NodesManager reference"
        );
        checkCondition(
            address(stakingManager.auctionManager()) == address(auctionManager),
            "StakingManager has correct AuctionManager reference"
        );

        // Verify EtherFiNodesManager knows about StakingManager
        console2.log("Checking EtherFiNodesManager contract references...");
        checkCondition(
            address(etherFiNodesManager.stakingManager()) ==
                address(stakingManager),
            "EtherFiNodesManager has correct StakingManager reference"
        );

        // Verify beacon is set correctly
        console2.log("Checking EtherFiNode beacon...");
        address beacon = stakingManager.getEtherFiNodeBeacon();
        checkCondition(beacon != address(0), "StakingManager has beacon set");
    }

    function getImplementation(address proxy) internal view returns (address) {
        bytes32 slot = IMPLEMENTATION_SLOT;
        bytes32 value = vm.load(proxy, slot);
        return address(uint160(uint256(value)));
    }

    function verifyAdditionalContracts() internal {
        // Verify EtherFiOracle upgradeability
        console2.log("Checking EtherFiOracle...");
        verifyProxyUpgradeability(etherFiOracle, "EtherFiOracle");

        // Verify EtherFiAdmin upgradeability
        console2.log("Checking EtherFiAdmin...");
        verifyProxyUpgradeability(etherFiAdmin, "EtherFiAdmin");

        // Verify eETH upgradeability
        console2.log("Checking eETH...");
        verifyProxyUpgradeability(eETH, "eETH");

        // Verify weETH upgradeability
        console2.log("Checking weETH...");
        verifyProxyUpgradeability(weETH, "weETH");

        // Verify TNFT upgradeability
        console2.log("Checking TNFT...");
        verifyProxyUpgradeability(TNFT, "TNFT");

        // Additional specific checks for these contracts
        console2.log("\nChecking EtherFiOracle specific functionality...");
        try IEtherFiOracle(etherFiOracle).consensusVersion() returns (
            uint32 version
        ) {
            checkCondition(
                version > 0,
                "EtherFiOracle consensusVersion() is accessible"
            );
        } catch {
            checkCondition(false, "EtherFiOracle consensusVersion() failed");
        }

        console2.log("\nChecking eETH token functionality...");
        try IeETH(eETH).totalShares() returns (uint256 shares) {
            checkCondition(
                shares > 0,
                "eETH totalShares() returns valid value"
            );
        } catch {
            checkCondition(false, "eETH totalShares() failed");
        }

        console2.log("\nChecking weETH token functionality...");
        console2.log(address(IWeETH(weETH).eETH()));
        console2.log(eETH);
        try IWeETH(weETH).eETH() returns (IeETH eethContract) {
            checkCondition(
                address(eethContract) == eETH,
                "weETH correctly references eETH"
            );
        } catch {
            checkCondition(false, "weETH eETH() reference check failed");
        }
    }

    function checkCondition(
        bool condition,
        string memory description
    ) internal {
        totalChecks++;
        if (condition) {
            passedChecks++;
            console2.log("\x1b[32m  [PASS]", description, "\x1b[0m");
        } else {
            allChecksPassed = false;
            console2.log("\x1b[31m  [FAIL]", description, "\x1b[0m");
        }
    }
}
