// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "forge-std/Script.sol";
import "forge-std/console2.sol";
import "../../utils/utils.sol";
import {PriorityWithdrawalQueue} from "../../../src/PriorityWithdrawalQueue.sol";
import {EtherFiOperationParameters} from "../../../src/helpers/EtherFiOperationParameters.sol";

// Combined batch: Liquidity Decision Params + Remove Whitelisted Addresses + Nonce Priority Fee
//   forge script script/operations/priority-queue/OperationsBatch.s.sol --fork-url $MAINNET_RPC_URL -vvvv
contract OperationsBatch is Script, Utils {
    PriorityWithdrawalQueue internal constant PRIORITY_QUEUE =
        PriorityWithdrawalQueue(payable(PRIORITY_WITHDRAWAL_QUEUE));
    EtherFiOperationParameters internal constant OPERATION_PARAMS =
        EtherFiOperationParameters(payable(ETHERFI_OPERATION_PARAMETERS));

    // --- Tag admins ---
    address internal constant PANKAJ_LEDGER = 0x1B7Fd9679B2678F7e01897E0A3BA9aF18dF4f71e;
    address internal constant ETHERFI_DEPLOYER = 0xf8a86ea1Ac39EC529814c377Bd484387D395421e;

    // --- Liquidity Decision Engine ---
    string internal constant LDE_TAG = "LIQUIDITY_DECISION_ENGINE";

    // --- Remove whitelisted addresses ---
    string internal constant FEE_TAG = "PRIORITY_USERS_FEE_BPS";
    address internal constant TEST_USER_1 = 0x6b6c4414f9fF7B1684380bc421A8b7036C040383;
    address internal constant TEST_USER_2 = 0xa0Ff21485e85d09eE3E59bc8Fa15a099E1C1a413;
    string internal constant TEST_USER_1_KEY = "0x6b6c4414f9fF7B1684380bc421A8b7036C040383";
    string internal constant TEST_USER_2_KEY = "0xa0Ff21485e85d09eE3E59bc8Fa15a099E1C1a413";

    // --- Nonce priority fee ---
    string internal constant NONCE_ADDRESS_KEY = "0xf0bb20865277aBd641a307eCe5Ee04E79073416C";

    function run() external {
        _writeGnosisTxFiles();
        _simulateOnFork();
    }

    // =====================================================================
    //  Batch: 2 LDE admins + 4 remove whitelist + 1 Nonce fee = 7 txns
    // =====================================================================

    function _writeGnosisTxFiles() internal {
        uint256 txCount = 2 + 4 + 1; // 7
        address[] memory targets = new address[](txCount);
        uint256[] memory values = new uint256[](txCount);
        bytes[] memory data = new bytes[](txCount);

        for (uint256 i = 0; i < txCount; i++) values[i] = 0;

        uint256 idx = 0;

        // --- 1. Liquidity Decision Engine tag admins (2 txns) ---

        targets[idx] = address(OPERATION_PARAMS);
        data[idx] = abi.encodeWithSelector(
            EtherFiOperationParameters.updateTagAdmin.selector,
            LDE_TAG, PANKAJ_LEDGER, true
        );
        idx++;

        targets[idx] = address(OPERATION_PARAMS);
        data[idx] = abi.encodeWithSelector(
            EtherFiOperationParameters.updateTagAdmin.selector,
            LDE_TAG, ETHERFI_DEPLOYER, true
        );
        idx++;

        // --- 2. Remove whitelisted addresses (4 txns) ---

        targets[idx] = address(PRIORITY_QUEUE);
        data[idx] = abi.encodeWithSelector(
            PriorityWithdrawalQueue.removeFromWhitelist.selector,
            TEST_USER_1
        );
        idx++;

        targets[idx] = address(PRIORITY_QUEUE);
        data[idx] = abi.encodeWithSelector(
            PriorityWithdrawalQueue.removeFromWhitelist.selector,
            TEST_USER_2
        );
        idx++;

        targets[idx] = address(OPERATION_PARAMS);
        data[idx] = abi.encodeWithSelector(
            EtherFiOperationParameters.updateTagKeyValue.selector,
            FEE_TAG, TEST_USER_1_KEY, ""
        );
        idx++;

        targets[idx] = address(OPERATION_PARAMS);
        data[idx] = abi.encodeWithSelector(
            EtherFiOperationParameters.updateTagKeyValue.selector,
            FEE_TAG, TEST_USER_2_KEY, ""
        );
        idx++;

        // --- 3. Nonce priority fee (1 txn) ---

        targets[idx] = address(OPERATION_PARAMS);
        data[idx] = abi.encodeWithSelector(
            EtherFiOperationParameters.updateTagKeyValue.selector,
            FEE_TAG, NONCE_ADDRESS_KEY, "0"
        );
        idx++;

        require(idx == txCount, "txCount mismatch");

        writeSafeJson(
            "script/operations/priority-queue",
            "operations-batch.json",
            ETHERFI_OPERATING_ADMIN,
            targets,
            values,
            data,
            1
        );
    }

    function _simulateOnFork() internal {
        vm.startPrank(ETHERFI_OPERATING_ADMIN);

        // 1. Liquidity Decision Engine tag admins
        OPERATION_PARAMS.updateTagAdmin(LDE_TAG, PANKAJ_LEDGER, true);
        OPERATION_PARAMS.updateTagAdmin(LDE_TAG, ETHERFI_DEPLOYER, true);

        // 2. Remove whitelisted addresses
        PRIORITY_QUEUE.removeFromWhitelist(TEST_USER_1);
        PRIORITY_QUEUE.removeFromWhitelist(TEST_USER_2);
        OPERATION_PARAMS.updateTagKeyValue(FEE_TAG, TEST_USER_1_KEY, "");
        OPERATION_PARAMS.updateTagKeyValue(FEE_TAG, TEST_USER_2_KEY, "");

        // 3. Nonce priority fee
        OPERATION_PARAMS.updateTagKeyValue(FEE_TAG, NONCE_ADDRESS_KEY, "0");

        vm.stopPrank();

        // Verify LDE tag admins
        console2.log("=== Liquidity Decision Engine ===");
        console2.log("Tag admin (Pankaj):", OPERATION_PARAMS.tagAdmins(LDE_TAG, PANKAJ_LEDGER));
        console2.log("Tag admin (Deployer):", OPERATION_PARAMS.tagAdmins(LDE_TAG, ETHERFI_DEPLOYER));
        require(OPERATION_PARAMS.tagAdmins(LDE_TAG, PANKAJ_LEDGER), "Pankaj not admin");
        require(OPERATION_PARAMS.tagAdmins(LDE_TAG, ETHERFI_DEPLOYER), "Deployer not admin");

        // Verify whitelist removal
        console2.log("");
        console2.log("=== Whitelist Removal ===");
        require(!PRIORITY_QUEUE.isWhitelisted(TEST_USER_1), "User 1 still whitelisted");
        require(!PRIORITY_QUEUE.isWhitelisted(TEST_USER_2), "User 2 still whitelisted");
        console2.log("User 1 whitelisted:", PRIORITY_QUEUE.isWhitelisted(TEST_USER_1));
        console2.log("User 2 whitelisted:", PRIORITY_QUEUE.isWhitelisted(TEST_USER_2));

        // Verify Nonce fee
        console2.log("");
        console2.log("=== Nonce Priority Fee ===");
        string memory nonceFee = OPERATION_PARAMS.tagKeyValues(FEE_TAG, NONCE_ADDRESS_KEY);
        console2.log("Nonce fee BPS:", nonceFee);
        require(
            keccak256(bytes(nonceFee)) == keccak256(bytes("0")),
            "Nonce fee not set to 0"
        );

        console2.log("");
        console2.log("All 7 transactions simulated successfully");
    }
}
