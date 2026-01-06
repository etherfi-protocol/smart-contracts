// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "forge-std/Script.sol";
import "forge-std/console2.sol";
import {UUPSUpgradeable} from "../../../lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import {RoleRegistry} from "../../../src/RoleRegistry.sol";
import {EtherFiTimelock} from "../../../src/EtherFiTimelock.sol";
import {EtherFiNodesManager} from "../../../src/EtherFiNodesManager.sol";
import {LiquidityPool} from "../../../src/LiquidityPool.sol";
import {IEtherFiNodesManager} from "../../../src/interfaces/IEtherFiNodesManager.sol";
import {ContractCodeChecker} from "../../ContractCodeChecker.sol";
import {Deployed} from "../../deploys/Deployed.s.sol";
import {Utils} from "../../utils/Utils.sol";

// forge script script/upgrades/CrossPodApproval/transactions.s.sol:LegacyLinkerRoleScript --fork-url $MAINNET_RPC_URL -vvvv
contract LegacyLinkerRoleScript is Script, Deployed, Utils {
    address constant liquidityPoolImpl = 0x4ba750e82F91839a4e18f39779B2Fec42c81d821;
    address constant etherFiNodesManagerImpl = 0x7431f88d669437F9A9A901E1086F8355A53E2e5d;

    EtherFiTimelock constant etherFiTimelock = EtherFiTimelock(payable(UPGRADE_TIMELOCK));
    RoleRegistry constant roleRegistry = RoleRegistry(ROLE_REGISTRY);
    uint256 constant TIMELOCK_MIN_DELAY = 259200;

    ContractCodeChecker public contractCodeChecker;


    bytes32 public ETHERFI_NODES_MANAGER_LEGACY_LINKER_ROLE;

    function run() public {
        console2.log("==============================================");
        console2.log("Grant legacy linker role to ETHERFI_OPERATING_ADMIN");
        console2.log("==============================================");

        string memory forkUrl = vm.envString("TENDERLY_TEST_RPC");
        vm.selectFork(vm.createFork(forkUrl));

        ETHERFI_NODES_MANAGER_LEGACY_LINKER_ROLE =
            EtherFiNodesManager(payable(etherFiNodesManagerImpl)).ETHERFI_NODES_MANAGER_LEGACY_LINKER_ROLE();

        address[] memory targets = new address[](3);
        bytes[] memory data = new bytes[](3);
        uint256[] memory values = new uint256[](3);

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
            ETHERFI_OPERATING_ADMIN
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

        contractCodeChecker = new ContractCodeChecker();
        verifyBytecode();
        checkUpgrade();
    }

    function checkUpgrade() internal {
        require(
            roleRegistry.hasRole(ETHERFI_NODES_MANAGER_LEGACY_LINKER_ROLE, ETHERFI_OPERATING_ADMIN),
            "role grant failed"
        );

        uint256[] memory validatorIds = new uint256[](1);
        validatorIds[0] = 10270;
        bytes[] memory pubkeys = new bytes[](1);
        pubkeys[0] = hex"8f9c0aab19ee7586d3d470f132842396af606947a0589382483308fdffdaf544078c3be24210677a9c471ce70b3b4c2c";

        vm.expectRevert(IEtherFiNodesManager.IncorrectRole.selector);
        vm.prank(OPERATING_TIMELOCK);
        EtherFiNodesManager(payable(ETHERFI_NODES_MANAGER)).linkLegacyValidatorIds(validatorIds, pubkeys);

        console2.log("[OK] Legacy linker role granted to ETHERFI_OPERATING_ADMIN");
        console2.log("================================================");
    }

    function verifyBytecode() internal {
        LiquidityPool newLiquidityPoolImplementation = new LiquidityPool();
        EtherFiNodesManager newEtherFiNodesManagerImplementation = new EtherFiNodesManager(
            address(STAKING_MANAGER),
            address(ROLE_REGISTRY),
            address(ETHERFI_RATE_LIMITER)
        );
        contractCodeChecker.verifyContractByteCodeMatch(liquidityPoolImpl, address(newLiquidityPoolImplementation));
        contractCodeChecker.verifyContractByteCodeMatch(etherFiNodesManagerImpl, address(newEtherFiNodesManagerImplementation));

        console2.log("[OK] Bytecode verified successfully");
    }
}
