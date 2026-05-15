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

/// @title BroadcastBatchCreate
/// @notice Broadcast `LiquidityPool.batchCreateBeaconValidators(...)` for every batch in the
///         payload JSON, signed by the EOA whose private key is in `PRIVATE_KEY`.
///
/// Pre-flight checks (revert before broadcasting anything):
///   - the EOA holds `LIQUIDITY_POOL_VALIDATOR_CREATOR_ROLE`
///   - every deposit in the payload is currently in `REGISTERED` state
///     (i.e. `batchRegister` has already happened on-chain)
///   - `LiquidityPool` has at least `1 ETH * totalValidators` of ETH
///
/// Run (dry-run, no txns sent):
///   PRIVATE_KEY=0x... \
///   forge script script/operations/batch-create-validators/BroadcastBatchCreate.s.sol:BroadcastBatchCreate \
///     --rpc-url $MAINNET_RPC_URL
///
/// Run (live, broadcasts 22 txns):
///   PRIVATE_KEY=0x... \
///   forge script script/operations/batch-create-validators/BroadcastBatchCreate.s.sol:BroadcastBatchCreate \
///     --rpc-url $MAINNET_RPC_URL --broadcast --slow
///
/// Env vars:
///   PRIVATE_KEY    — signer key (required)
///   PAYLOAD_PATH   — path to payload JSON, project-relative
///                    (default: "script/operations/batch-create-validators/payload.json")
contract BroadcastBatchCreate is Script, Utils {
    using StringHelpers for uint256;

    string constant DEFAULT_PAYLOAD = "script/operations/batch-create-validators/payload.json";

    LiquidityPool  internal lp = LiquidityPool(payable(LIQUIDITY_POOL));
    StakingManager internal sm = StakingManager(STAKING_MANAGER);
    RoleRegistry   internal rr = RoleRegistry(ROLE_REGISTRY);

    function run() external {
        uint256 pk     = vm.envUint("PRIVATE_KEY");
        address signer = vm.addr(pk);
        string memory payloadPath = vm.envOr("PAYLOAD_PATH", DEFAULT_PAYLOAD);
        string memory absPayload  = string.concat(vm.projectRoot(), "/", payloadPath);
        string memory json = vm.readFile(absPayload);

        uint256 batchCount = vm.parseJsonUint(json, ".count");
        require(batchCount > 0, "no batches");

        console2.log("=== BroadcastBatchCreate ===");
        console2.log("Signer:       ", signer);
        console2.log("Payload:      ", absPayload);
        console2.log("Batches:      ", batchCount);
        console2.log("Block:        ", block.number);
        console2.log("Chain id:     ", block.chainid);

        _preflight(json, batchCount, signer);

        uint256 lpBalanceStart = address(lp).balance;
        uint256 totalCreated = 0;

        vm.startBroadcast(pk);
        for (uint256 i = 0; i < batchCount; i++) {
            uint256 created = _broadcastBatch(json, i);
            totalCreated += created;
        }
        vm.stopBroadcast();

        uint256 lpBalanceEnd = address(lp).balance;
        uint256 expectedDelta = 1 ether * totalCreated;
        require(
            lpBalanceStart - lpBalanceEnd == expectedDelta,
            "LP balance delta != 1 ETH * total created"
        );

        console2.log("");
        console2.log("=== SUMMARY ===");
        console2.log("Batches broadcast:    ", batchCount);
        console2.log("Validators created:   ", totalCreated);
        console2.log("LP balance before:    ", lpBalanceStart);
        console2.log("LP balance after:     ", lpBalanceEnd);
        console2.log("LP balance delta:     ", lpBalanceStart - lpBalanceEnd);
        console2.log("Expected delta:       ", expectedDelta);
        console2.log(unicode"✓ all batches broadcast; LP balance delta matches 1 ETH/validator");
    }

    function _preflight(string memory json, uint256 batchCount, address signer) internal view {
        // 1) signer must hold LIQUIDITY_POOL_VALIDATOR_CREATOR_ROLE
        bytes32 creatorRole = lp.LIQUIDITY_POOL_VALIDATOR_CREATOR_ROLE();
        require(
            rr.hasRole(creatorRole, signer),
            "signer missing LIQUIDITY_POOL_VALIDATOR_CREATOR_ROLE"
        );

        // 2) every deposit must be in REGISTERED state, and LP must have enough ETH
        uint256 totalValidators = 0;
        for (uint256 i = 0; i < batchCount; i++) {
            string memory base = string.concat(".batches[", i.uint256ToString(), "]");
            address etherFiNode      = vm.parseJsonAddress    (json, string.concat(base, ".etherFiNode"));
            uint256[] memory bidIds  = vm.parseJsonUintArray  (json, string.concat(base, ".bidIds"));
            bytes[]   memory pubkeys = vm.parseJsonBytesArray (json, string.concat(base, ".publicKeys"));
            bytes[]   memory sigs    = vm.parseJsonBytesArray (json, string.concat(base, ".signatures"));
            bytes32[] memory roots   = vm.parseJsonBytes32Array(json, string.concat(base, ".depositDataRoots"));

            for (uint256 j = 0; j < bidIds.length; j++) {
                IStakingManager.DepositData memory d = IStakingManager.DepositData({
                    publicKey: pubkeys[j],
                    signature: sigs[j],
                    depositDataRoot: roots[j],
                    ipfsHashForEncryptedValidatorKey: ""
                });
                IStakingManager.ValidatorCreationStatus s = _statusOf(d, bidIds[j], etherFiNode);
                require(
                    s == IStakingManager.ValidatorCreationStatus.REGISTERED,
                    "deposit not in REGISTERED state"
                );
            }
            totalValidators += bidIds.length;
        }

        uint256 required = 1 ether * totalValidators;
        require(address(lp).balance >= required, "LP balance < 1 ETH * validators");

        console2.log(unicode"✓ preflight: signer holds VALIDATOR_CREATOR_ROLE");
        console2.log(unicode"✓ preflight: all", totalValidators, "deposits in REGISTERED state");
        console2.log(unicode"✓ preflight: LP balance sufficient");
    }

    function _broadcastBatch(string memory json, uint256 i) internal returns (uint256 createdCount) {
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

        console2.log("");
        console2.log("--- batch", i, "---");
        console2.log("  etherFiNode: ", etherFiNode);
        console2.log("  validators:  ", deposits.length);
        console2.log("  first bidId: ", bidIds[0]);

        lp.batchCreateBeaconValidators(deposits, bidIds, etherFiNode);

        createdCount = deposits.length;
        console2.log(unicode"  ✓ broadcast (", createdCount, "validators)");
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
