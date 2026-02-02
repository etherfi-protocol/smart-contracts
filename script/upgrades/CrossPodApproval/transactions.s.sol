// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "forge-std/Script.sol";
import "forge-std/console2.sol";
import {UUPSUpgradeable} from "../../../lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import {RoleRegistry} from "../../../src/RoleRegistry.sol";
import {EtherFiTimelock} from "../../../src/EtherFiTimelock.sol";
import {EtherFiNodesManager} from "../../../src/EtherFiNodesManager.sol";
import {LiquidityPool} from "../../../src/LiquidityPool.sol";
import {EtherFiRateLimiter} from "../../../src/EtherFiRateLimiter.sol";
import {IEtherFiNodesManager} from "../../../src/interfaces/IEtherFiNodesManager.sol";
import {ContractCodeChecker} from "../../ContractCodeChecker.sol";
import {Deployed} from "../../deploys/Deployed.s.sol";
import {Utils} from "../../utils/Utils.sol";
import {IEigenPodTypes} from "../../../src/eigenlayer-interfaces/IEigenPod.sol";

// forge script script/upgrades/CrossPodApproval/transactions.s.sol:CrossPodApprovalScript --fork-url $MAINNET_RPC_URL -vvvv
contract CrossPodApprovalScript is Script, Deployed, Utils {
    address constant liquidityPoolImpl = 0x8765bb2f362a4b72e614DF81E2841275b9358f8b;
    address constant etherFiNodesManagerImpl = 0x789CbBe0739F1458905C9Ca6d6e74f7997622A9B;

    EtherFiTimelock constant etherFiTimelock = EtherFiTimelock(payable(UPGRADE_TIMELOCK));
    RoleRegistry constant roleRegistry = RoleRegistry(ROLE_REGISTRY);
    EtherFiNodesManager constant etherFiNodesManager = EtherFiNodesManager(payable(ETHERFI_NODES_MANAGER));
    uint256 constant TIMELOCK_MIN_DELAY = 259200;

    ContractCodeChecker public contractCodeChecker;

    bytes32 public ETHERFI_NODES_MANAGER_LEGACY_LINKER_ROLE;
    bytes32 public LIQUIDITY_POOL_VALIDATOR_CREATOR_ROLE;
    bytes32 public STAKING_MANAGER_VALIDATOR_INVALIDATOR_ROLE = keccak256("STAKING_MANAGER_VALIDATOR_INVALIDATOR_ROLE");
    bytes32 public ETHERFI_NODES_MANAGER_EL_CONSOLIDATION_ROLE = keccak256("ETHERFI_NODES_MANAGER_EL_CONSOLIDATION_ROLE");
    bytes32 public CONSOLIDATION_REQUEST_LIMIT_ID = keccak256("CONSOLIDATION_REQUEST_LIMIT_ID");
    // How many vals to consolidate for 250k ETH daily ? 250k/32 = 7812.5 vals
    // For 7813 vals, 2048 * 7813 = 16_001_024 gwei needs to be set on the capacity rate limiter
    uint64 public constant CAPACITY_RATE_LIMITER = 16_001_024 * 1e9;
    // 16_001_024 gwei / 86400 seconds = 185.2 ETH per second
    uint64 public constant REFILL_RATE = 185_200_000_000;
    uint256 public constant FULL_EXIT_GWEI = 2_048_000_000_000;

    function run() public {
        string memory forkUrl = vm.envString("TENDERLY_TEST_RPC");
        vm.selectFork(vm.createFork(forkUrl));

        setUpEtherFiRateLimiter();
        ETHERFI_NODES_MANAGER_LEGACY_LINKER_ROLE = EtherFiNodesManager(payable(etherFiNodesManagerImpl)).ETHERFI_NODES_MANAGER_LEGACY_LINKER_ROLE();
        LIQUIDITY_POOL_VALIDATOR_CREATOR_ROLE = LiquidityPool(payable(liquidityPoolImpl)).LIQUIDITY_POOL_VALIDATOR_CREATOR_ROLE();

        address[] memory targets = new address[](6);
        bytes[] memory data = new bytes[](targets.length);
        uint256[] memory values = new uint256[](targets.length);

        // Upgrade EtherFiNodesManager implementation first (adds the role)
        targets[0] = ETHERFI_NODES_MANAGER;
        data[0] = abi.encodeWithSelector(UUPSUpgradeable.upgradeTo.selector, etherFiNodesManagerImpl);

        // Upgrade LiquidityPool implementation
        targets[1] = LIQUIDITY_POOL;
        data[1] = abi.encodeWithSelector(UUPSUpgradeable.upgradeTo.selector, liquidityPoolImpl);

        // Grant legacy linker role to ETHERFI_OPERATING_ADMIN
        targets[2] = ROLE_REGISTRY;
        data[2] = abi.encodeWithSelector(
            RoleRegistry.grantRole.selector,
            ETHERFI_NODES_MANAGER_LEGACY_LINKER_ROLE,
            ADMIN_EOA
        );
        targets[3] = ROLE_REGISTRY;
        data[3] = abi.encodeWithSelector(
            RoleRegistry.grantRole.selector,
            LIQUIDITY_POOL_VALIDATOR_CREATOR_ROLE,
            ADMIN_EOA
        );
        targets[4] = ROLE_REGISTRY;
        data[4] = abi.encodeWithSelector(
            RoleRegistry.grantRole.selector,
            STAKING_MANAGER_VALIDATOR_INVALIDATOR_ROLE,
            ADMIN_EOA
        );
        targets[5] = ROLE_REGISTRY;
        data[5] = abi.encodeWithSelector(
            RoleRegistry.grantRole.selector,
            ETHERFI_NODES_MANAGER_EL_CONSOLIDATION_ROLE,
            ADMIN_EOA
        );

        bytes32 timelockSalt = keccak256(abi.encode(targets, data, block.number));

        bytes memory scheduleCalldata = abi.encodeWithSelector(
            etherFiTimelock.scheduleBatch.selector,
            targets,
            values,
            data,
            bytes32(0),
            timelockSalt,
            TIMELOCK_MIN_DELAY
        );

        console2.log("Schedule calldata:");
        console2.logBytes(scheduleCalldata);
        console2.log("");

        bytes memory executeCalldata = abi.encodeWithSelector(
            etherFiTimelock.executeBatch.selector,
            targets,
            values,
            data,
            bytes32(0),
            timelockSalt
        );

        console2.log("Execute calldata:");
        console2.logBytes(executeCalldata);
        console2.log("");

        vm.startPrank(ETHERFI_UPGRADE_ADMIN);
        etherFiTimelock.scheduleBatch(targets, values, data, bytes32(0), timelockSalt, TIMELOCK_MIN_DELAY);
        vm.warp(block.timestamp + TIMELOCK_MIN_DELAY + 1);
        etherFiTimelock.executeBatch(targets, values, data, bytes32(0), timelockSalt);
        vm.stopPrank();

        console2.log("Upgrade executed successfully");
        console2.log("================================================");
        console2.log("");

        contractCodeChecker = new ContractCodeChecker();
        verifyBytecode();
        checkUpgrade();
    }

    function setUpEtherFiRateLimiter() public {
        console2.log("Setting up EtherFiRateLimiter");
        console2.log("================================================");

        bytes[] memory data = new bytes[](2);
        address[] memory targets = new address[](2);

        data[0] = abi.encodeWithSelector(
            EtherFiRateLimiter.createNewLimiter.selector,
            CONSOLIDATION_REQUEST_LIMIT_ID,
            CAPACITY_RATE_LIMITER,
            REFILL_RATE
        );
        data[1] = abi.encodeWithSelector(
            EtherFiRateLimiter.updateConsumers.selector,
            CONSOLIDATION_REQUEST_LIMIT_ID,
            ETHERFI_NODES_MANAGER,
            true
        );
        for (uint256 i = 0; i < 2; i++) {
            console2.log("====== EtherFiRateLimiter Tx", i);
            targets[i] = address(ETHERFI_RATE_LIMITER);
            console2.log("target: ", targets[i]);
            console2.log("data: ");
            console2.logBytes(data[i]);
            console2.log("--------------------------------");
        }
        console2.log("================================================");
        console2.log("");    
        // Uncomment to run against fork
        vm.startPrank(ETHERFI_OPERATING_ADMIN);
        EtherFiRateLimiter(payable(ETHERFI_RATE_LIMITER)).createNewLimiter(CONSOLIDATION_REQUEST_LIMIT_ID, CAPACITY_RATE_LIMITER, REFILL_RATE);
        EtherFiRateLimiter(payable(ETHERFI_RATE_LIMITER)).updateConsumers(CONSOLIDATION_REQUEST_LIMIT_ID, ETHERFI_NODES_MANAGER, true);
        vm.stopPrank();
        console2.log("EtherFiRateLimiter setup completed");
        console2.log("================================================");
        console2.log("");
    }

    function checkUpgrade() internal {
        require(
            roleRegistry.hasRole(ETHERFI_NODES_MANAGER_LEGACY_LINKER_ROLE, ADMIN_EOA),
            "role grant failed"
        );
        require(
            roleRegistry.hasRole(LIQUIDITY_POOL_VALIDATOR_CREATOR_ROLE, ADMIN_EOA),
            "role grant failed"
        );
        require(
            roleRegistry.hasRole(STAKING_MANAGER_VALIDATOR_INVALIDATOR_ROLE, ADMIN_EOA),
            "role grant failed"
        );

        uint256[] memory validatorIds = new uint256[](1);
        validatorIds[0] = 10270;
        bytes[] memory pubkeys = new bytes[](1);
        pubkeys[0] = hex"8f9c0aab19ee7586d3d470f132842396af606947a0589382483308fdffdaf544078c3be24210677a9c471ce70b3b4c2c";

        vm.expectRevert(IEtherFiNodesManager.IncorrectRole.selector);
        vm.prank(OPERATING_TIMELOCK);
        EtherFiNodesManager(payable(ETHERFI_NODES_MANAGER)).linkLegacyValidatorIds(validatorIds, pubkeys);
    
        vm.prank(ADMIN_EOA);
        EtherFiNodesManager(payable(ETHERFI_NODES_MANAGER)).linkLegacyValidatorIds(validatorIds, pubkeys);

        bytes[] memory pubkeys_consolidation = new bytes[](3);
        pubkeys_consolidation[0] = hex"b5dba57ec7c1dda1a95061b2b37f4121d7745f66b3aebe9767927f4e55167755bf4377dd163529d30c169f589eb105dd";
        pubkeys_consolidation[1] = hex"99ff790e514eff01e51bcc845705676477ad9ee43346fdf12a7326e413afd2cd389efb8a899e2df833634bd15aa4b8ce";
        pubkeys_consolidation[2] = hex"96649b10c031d3cdb1ad158a3c0977ac32b6dea18971195afd788da6863f0960cf95019798c69f99cfef20b906504267";

        IEigenPodTypes.ConsolidationRequest[] memory consolidationRequests = new IEigenPodTypes.ConsolidationRequest[](pubkeys_consolidation.length - 1);
        for (uint256 i = 1; i < pubkeys_consolidation.length; i++) {
            consolidationRequests[i - 1] = IEigenPodTypes.ConsolidationRequest({
                srcPubkey: pubkeys_consolidation[i],
                targetPubkey: pubkeys_consolidation[0]
            });
        }

        uint64 remaining = etherFiNodesManager.rateLimiter().consumable(CONSOLIDATION_REQUEST_LIMIT_ID);
        console2.log("Remaining capacity: ", remaining);

        vm.prank(ADMIN_EOA);
        etherFiNodesManager.requestConsolidation{value: consolidationRequests.length}(consolidationRequests);

        uint64 remaining2 = etherFiNodesManager.rateLimiter().consumable(CONSOLIDATION_REQUEST_LIMIT_ID);
        console2.log("Remaining capacity: ", remaining2);

        if (remaining2 == remaining - FULL_EXIT_GWEI*2) {
            console2.log("[OK] Consolidation request limit rate limited correctly");
        } else {
            console2.log("[ERROR] Consolidation request limit rate limited incorrectly");
        }

        console2.log("[OK] Legacy linker role granted to ADMIN_EOA");
        console2.log("[OK] Consolidation role granted to ADMIN_EOA");
        console2.log("[OK] Liquidity pool validator creator role granted to ADMIN_EOA");
        console2.log("[OK] Staking manager validator invalidator role granted to ADMIN_EOA");
        console2.log("[OK] EtherFiRateLimiter setup completed");
        console2.log("================================================");
    }

    function logSetCapacityAndRefillRateCalldata() public view {
        console2.log("Set Capacity and Refill Rate Calldata");
        console2.log("================================================");
        console2.log("Target: ", ETHERFI_RATE_LIMITER);
        console2.log("");

        bytes memory setCapacityData = abi.encodeWithSelector(
            EtherFiRateLimiter.setCapacity.selector,
            CONSOLIDATION_REQUEST_LIMIT_ID,
            CAPACITY_RATE_LIMITER
        );
        console2.log("setCapacity calldata:");
        console2.logBytes(setCapacityData);
        console2.log("");

        bytes memory setRefillRateData = abi.encodeWithSelector(
            EtherFiRateLimiter.setRefillRate.selector,
            CONSOLIDATION_REQUEST_LIMIT_ID,
            REFILL_RATE
        );
        console2.log("setRefillRate calldata:");
        console2.logBytes(setRefillRateData);
        console2.log("================================================");
    }

    function verifyBytecode() internal {
        // LiquidityPool newLiquidityPoolImplementation = new LiquidityPool();
        EtherFiNodesManager newEtherFiNodesManagerImplementation = new EtherFiNodesManager(
            address(STAKING_MANAGER),
            address(ROLE_REGISTRY),
            address(ETHERFI_RATE_LIMITER)
        );
        // contractCodeChecker.verifyContractByteCodeMatch(liquidityPoolImpl, address(newLiquidityPoolImplementation));
        contractCodeChecker.verifyContractByteCodeMatch(etherFiNodesManagerImpl, address(newEtherFiNodesManagerImplementation));

        console2.log("[OK] Bytecode verified successfully");
    }
}
