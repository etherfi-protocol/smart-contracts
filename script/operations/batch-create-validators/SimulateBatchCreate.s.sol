// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "forge-std/Script.sol";
import "forge-std/console2.sol";

import {ILiquidityPool}    from "../../../src/interfaces/ILiquidityPool.sol";
import {IStakingManager}   from "../../../src/interfaces/IStakingManager.sol";
import {LiquidityPool}     from "../../../src/LiquidityPool.sol";
import {StakingManager}    from "../../../src/StakingManager.sol";
import {RoleRegistry}      from "../../../src/RoleRegistry.sol";

import {Utils}             from "../../utils/utils.sol";
import {StringHelpers}     from "../../utils/StringHelpers.sol";

/// @title SimulateBatchCreate
/// @notice Forks mainnet, grants the required role to the prank address, and replays every
///         batch in the payload JSON against `LiquidityPool.batchCreateBeaconValidators(...)`.
///
/// Confirms end-to-end that the calldata emitted by BatchCreateBeaconValidators.s.sol
/// will succeed when signed by the Safe (or any address holding
/// LIQUIDITY_POOL_VALIDATOR_CREATOR_ROLE).
///
/// Run:
///   PRANK_AS=0x12582A27E5e19492b4FcD194a60F8f5e1aa31B0F \
///   forge script script/operations/batch-create-validators/SimulateBatchCreate.s.sol:SimulateBatchCreate \
///     --fork-url $MAINNET_RPC_URL
///
/// Env vars:
///   PRANK_AS      — address to prank as (default: ADMIN_EOA)
///   PAYLOAD_PATH  — path to payload JSON
///                   (default: "script/operations/batch-create-validators/payload.json")
contract SimulateBatchCreate is Script, Utils {
    using StringHelpers for uint256;

    string constant DEFAULT_PAYLOAD = "script/operations/batch-create-validators/payload.json";

    LiquidityPool  internal lp   = LiquidityPool(payable(LIQUIDITY_POOL));
    StakingManager internal sm   = StakingManager(STAKING_MANAGER);
    RoleRegistry   internal rr   = RoleRegistry(ROLE_REGISTRY);

    function run() external {
        address prankAs = vm.envOr("PRANK_AS", ADMIN_EOA);
        string memory payloadPath = vm.envOr("PAYLOAD_PATH", DEFAULT_PAYLOAD);
        string memory absPayload = string.concat(vm.projectRoot(), "/", payloadPath);
        string memory json = vm.readFile(absPayload);

        uint256 batchCount = vm.parseJsonUint(json, ".count");
        require(batchCount > 0, "no batches");

        console2.log("=== SimulateBatchCreate ===");
        console2.log("Prank as:    ", prankAs);
        console2.log("Payload:     ", absPayload);
        console2.log("Batches:     ", batchCount);
        console2.log("Block:       ", block.number);

        _grantRolesAndRegisterSpawner(prankAs);

        uint256 totalCreated = 0;
        uint256 totalRegistered = 0;
        uint256 lpBalanceStart = address(lp).balance;

        for (uint256 i = 0; i < batchCount; i++) {
            (uint256 registered, uint256 created) = _simulateBatch(json, i, prankAs);
            totalRegistered += registered;
            totalCreated    += created;
        }

        uint256 lpBalanceEnd = address(lp).balance;
        uint256 expectedDelta = 1 ether * totalCreated;
        require(
            lpBalanceStart - lpBalanceEnd == expectedDelta,
            "LP cumulative balance delta != 1 ETH * total created"
        );

        console2.log("");
        console2.log("=== SUMMARY ===");
        console2.log("Batches processed:  ", batchCount);
        console2.log("Validators registered (this run):", totalRegistered);
        console2.log("Validators created  (this run):  ", totalCreated);
        console2.log("LP balance before (wei):         ", lpBalanceStart);
        console2.log("LP balance after  (wei):         ", lpBalanceEnd);
        console2.log("LP balance delta  (wei):         ", lpBalanceStart - lpBalanceEnd);
        console2.log("Expected delta    (wei):         ", expectedDelta);
        console2.log(unicode"✓ all batches executed successfully");
        console2.log(unicode"✓ LP balance dropped by exactly 1 ETH per validator");
    }

    function _grantRolesAndRegisterSpawner(address who) internal {
        bytes32 creatorRole = lp.LIQUIDITY_POOL_VALIDATOR_CREATOR_ROLE();
        bytes32 adminRole   = lp.LIQUIDITY_POOL_ADMIN_ROLE();

        address owner = rr.owner();
        vm.startPrank(owner);
        if (!rr.hasRole(creatorRole, who))   rr.grantRole(creatorRole, who);
        if (!rr.hasRole(adminRole,   owner)) rr.grantRole(adminRole, owner);
        vm.stopPrank();

        // register `who` as a validator spawner if not already (needed for batchRegister)
        (bool registered) = lp.validatorSpawner(who);
        if (!registered) {
            vm.prank(owner);
            lp.registerValidatorSpawner(who);
        }

        console2.log("Granted LIQUIDITY_POOL_VALIDATOR_CREATOR_ROLE to:", who);
        console2.log("Registered validator spawner:                    ", who);
    }

    function _simulateBatch(string memory json, uint256 i, address prankAs)
        internal
        returns (uint256 registeredCount, uint256 createdCount)
    {
        string memory base = string.concat(".batches[", i.uint256ToString(), "]");

        address etherFiNode         = vm.parseJsonAddress    (json, string.concat(base, ".etherFiNode"));
        uint256[] memory bidIds     = vm.parseJsonUintArray  (json, string.concat(base, ".bidIds"));
        bytes[]   memory pubkeys    = vm.parseJsonBytesArray (json, string.concat(base, ".publicKeys"));
        bytes[]   memory signatures = vm.parseJsonBytesArray (json, string.concat(base, ".signatures"));
        bytes32[] memory roots      = vm.parseJsonBytes32Array(json, string.concat(base, ".depositDataRoots"));

        IStakingManager.DepositData[] memory deposits =
            new IStakingManager.DepositData[](bidIds.length);
        for (uint256 j = 0; j < bidIds.length; j++) {
            deposits[j] = IStakingManager.DepositData({
                publicKey: pubkeys[j],
                signature: signatures[j],
                depositDataRoot: roots[j],
                ipfsHashForEncryptedValidatorKey: ""
            });
        }

        // Snapshot statuses across the batch — if any are NOT_REGISTERED we'll register first.
        bool needRegister = false;
        bool anyAlreadyConfirmed = false;
        for (uint256 j = 0; j < deposits.length; j++) {
            IStakingManager.ValidatorCreationStatus s = _statusOf(deposits[j], bidIds[j], etherFiNode);
            if (s == IStakingManager.ValidatorCreationStatus.NOT_REGISTERED) needRegister = true;
            if (s == IStakingManager.ValidatorCreationStatus.CONFIRMED)      anyAlreadyConfirmed = true;
        }

        console2.log("");
        console2.log("--- batch", i, "---");
        console2.log("  etherFiNode:    ", etherFiNode);
        console2.log("  validators:     ", deposits.length);
        console2.log("  first bidId:    ", bidIds[0]);

        require(!anyAlreadyConfirmed, "one or more deposits already CONFIRMED on mainnet");

        if (needRegister) {
            vm.prank(prankAs);
            lp.batchRegister(deposits, bidIds, etherFiNode);
            registeredCount = deposits.length;
            console2.log("  registered:     ", registeredCount);
        }

        uint256 lpBalanceBefore = address(lp).balance;
        vm.prank(prankAs);
        lp.batchCreateBeaconValidators(deposits, bidIds, etherFiNode);
        uint256 lpBalanceAfter = address(lp).balance;
        createdCount = deposits.length;

        uint256 expectedDelta = 1 ether * createdCount;
        require(
            lpBalanceBefore - lpBalanceAfter == expectedDelta,
            "LP balance delta != 1 ETH * validators created"
        );
        console2.log(unicode"  ✓ created:      ", createdCount);
        console2.log("  LP balance drop (wei):", lpBalanceBefore - lpBalanceAfter);

        // Post-state assertion: every deposit should now be CONFIRMED
        for (uint256 j = 0; j < deposits.length; j++) {
            IStakingManager.ValidatorCreationStatus s = _statusOf(deposits[j], bidIds[j], etherFiNode);
            require(s == IStakingManager.ValidatorCreationStatus.CONFIRMED, "status not CONFIRMED after create");
        }
    }

    function _statusOf(
        IStakingManager.DepositData memory d,
        uint256 bidId,
        address etherFiNode
    ) internal view returns (IStakingManager.ValidatorCreationStatus) {
        bytes32 h = keccak256(abi.encode(
            d.publicKey, d.signature, d.depositDataRoot, d.ipfsHashForEncryptedValidatorKey, bidId, etherFiNode
        ));
        return sm.validatorCreationStatus(h);
    }
}
