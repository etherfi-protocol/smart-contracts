// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "forge-std/Script.sol";
import "forge-std/console2.sol";
import "../../utils/utils.sol";
import "../../../src/helpers/EtherFiOperationParameters.sol";

// Generate direct calldata for Operations Params updates:
// forge script script/upgrades/priority-queue/SetPriorityQueueParams.s.sol --fork-url $MAINNET_RPC_URL -vvvv
contract SetPriorityQueueParams is Script, Utils {
    EtherFiOperationParameters internal constant _OPERATION_PARAMS =
        EtherFiOperationParameters(payable(ETHERFI_OPERATION_PARAMETERS));

    string internal constant _PRIORITY_WITHDRAWAL = "PRIORITY_WITHDRAWAL";
    string internal constant _PRIORITY_USERS_FEE_BPS = "PRIORITY_USERS_FEE_BPS";
    string internal constant _ORACLE = "ORACLE";
    string internal constant _ESTIMATED_WD_TIME_SECONDS = "14400";
    string internal constant _TEST_PRIORITY_USER = "0x6b6c4414f9fF7B1684380bc421A8b7036C040383";
    address internal constant _PANKAJ_LEDGER = 0x1B7Fd9679B2678F7e01897E0A3BA9aF18dF4f71e;

    function run() external {
        _printCalldata();
        _writeGnosisTxFiles();
        _simulateOnFork();
    }

    function _printCalldata() internal view {
        bytes memory a1 = abi.encodeWithSelector(
            EtherFiOperationParameters.updateTagAdmin.selector,
            _PRIORITY_WITHDRAWAL,
            ETHERFI_OPERATING_ADMIN,
            true
        );
        bytes memory a2 = abi.encodeWithSelector(
            EtherFiOperationParameters.updateTagAdmin.selector,
            _PRIORITY_USERS_FEE_BPS,
            ETHERFI_OPERATING_ADMIN,
            true
        );
        bytes memory a3 = abi.encodeWithSelector(
            EtherFiOperationParameters.updateTagAdmin.selector,
            _ORACLE,
            _PANKAJ_LEDGER,
            true
        );

        bytes memory c1 = abi.encodeWithSelector(
            EtherFiOperationParameters.updateTagKeyValue.selector,
            _PRIORITY_WITHDRAWAL,
            "AUTO_FULFILL_LIMIT_ETH",
            "5000"
        );
        bytes memory c2 = abi.encodeWithSelector(
            EtherFiOperationParameters.updateTagKeyValue.selector,
            _PRIORITY_WITHDRAWAL,
            "DAILY_CAP_PER_USER_ETH",
            "10000"
        );
        bytes memory c3 = abi.encodeWithSelector(
            EtherFiOperationParameters.updateTagKeyValue.selector,
            _PRIORITY_WITHDRAWAL,
            "WEEKLY_CAP_PER_USER_ETH",
            "50000"
        );
        bytes memory c4 = abi.encodeWithSelector(
            EtherFiOperationParameters.updateTagKeyValue.selector,
            _PRIORITY_WITHDRAWAL,
            "FINALIZED_NOT_CLAIMED_EXPIRY_DAYS",
            "5"
        );
        bytes memory c5 = abi.encodeWithSelector(
            EtherFiOperationParameters.updateTagKeyValue.selector,
            _PRIORITY_WITHDRAWAL,
            "ESTIMATED_WD_TIME",
            _ESTIMATED_WD_TIME_SECONDS
        );
        bytes memory c6 = abi.encodeWithSelector(
            EtherFiOperationParameters.updateTagKeyValue.selector,
            _PRIORITY_USERS_FEE_BPS,
            _TEST_PRIORITY_USER,
            "100"
        );

        console2.log("Target (all direct calls):", address(_OPERATION_PARAMS));
        console2.log("");

        console2.log("A1) updateTagAdmin(PRIORITY_WITHDRAWAL, ETHERFI_OPERATING_ADMIN, true)");
        console2.logBytes(a1);
        console2.log("");

        console2.log("A2) updateTagAdmin(PRIORITY_USERS_FEE_BPS, ETHERFI_OPERATING_ADMIN, true)");
        console2.logBytes(a2);
        console2.log("");

        console2.log("A3) updateTagAdmin(ORACLE, 0x1B7Fd9679B2678F7e01897E0A3BA9aF18dF4f71e, true)");
        console2.logBytes(a3);
        console2.log("");

        console2.log("1) PRIORITY_WITHDRAWAL.AUTO_FULFILL_LIMIT_ETH = 5000");
        console2.logBytes(c1);
        console2.log("");

        console2.log("2) PRIORITY_WITHDRAWAL.DAILY_CAP_PER_USER_ETH = 10000");
        console2.logBytes(c2);
        console2.log("");

        console2.log("3) PRIORITY_WITHDRAWAL.WEEKLY_CAP_PER_USER_ETH = 50000");
        console2.logBytes(c3);
        console2.log("");

        console2.log("4) PRIORITY_WITHDRAWAL.FINALIZED_NOT_CLAIMED_EXPIRY_DAYS = 5");
        console2.logBytes(c4);
        console2.log("");

        console2.log("5) PRIORITY_WITHDRAWAL.ESTIMATED_WD_TIME = 14400");
        console2.logBytes(c5);
        console2.log("");

        console2.log("6) PRIORITY_USERS_FEE_BPS[0x6b6c4414f9fF7B1684380bc421A8b7036C040383] = 100");
        console2.logBytes(c6);
    }

    function _simulateOnFork() internal {
        vm.startPrank(ETHERFI_OPERATING_ADMIN);
        _OPERATION_PARAMS.updateTagAdmin(_PRIORITY_WITHDRAWAL, ETHERFI_OPERATING_ADMIN, true);
        _OPERATION_PARAMS.updateTagAdmin(_PRIORITY_USERS_FEE_BPS, ETHERFI_OPERATING_ADMIN, true);
        _OPERATION_PARAMS.updateTagAdmin(_ORACLE, _PANKAJ_LEDGER, true);
        _OPERATION_PARAMS.updateTagKeyValue(_PRIORITY_WITHDRAWAL, "AUTO_FULFILL_LIMIT_ETH", "5000");
        _OPERATION_PARAMS.updateTagKeyValue(_PRIORITY_WITHDRAWAL, "DAILY_CAP_PER_USER_ETH", "10000");
        _OPERATION_PARAMS.updateTagKeyValue(_PRIORITY_WITHDRAWAL, "WEEKLY_CAP_PER_USER_ETH", "50000");
        _OPERATION_PARAMS.updateTagKeyValue(_PRIORITY_WITHDRAWAL, "FINALIZED_NOT_CLAIMED_EXPIRY_DAYS", "5");
        _OPERATION_PARAMS.updateTagKeyValue(_PRIORITY_WITHDRAWAL, "ESTIMATED_WD_TIME", _ESTIMATED_WD_TIME_SECONDS);
        _OPERATION_PARAMS.updateTagKeyValue(_PRIORITY_USERS_FEE_BPS, _TEST_PRIORITY_USER, "100");
        vm.stopPrank();
    }

    function _writeGnosisTxFiles() internal {
        address[] memory targets = new address[](9);
        uint256[] memory values = new uint256[](9);
        bytes[] memory data = new bytes[](9);

        for (uint256 i = 0; i < 9; i++) {
            targets[i] = address(_OPERATION_PARAMS);
            values[i] = 0;
        }

        data[0] = abi.encodeWithSelector(
            EtherFiOperationParameters.updateTagAdmin.selector,
            _PRIORITY_WITHDRAWAL,
            ETHERFI_OPERATING_ADMIN,
            true
        );
        data[1] = abi.encodeWithSelector(
            EtherFiOperationParameters.updateTagAdmin.selector,
            _PRIORITY_USERS_FEE_BPS,
            ETHERFI_OPERATING_ADMIN,
            true
        );
        data[2] = abi.encodeWithSelector(
            EtherFiOperationParameters.updateTagAdmin.selector,
            _ORACLE,
            _PANKAJ_LEDGER,
            true
        );
        data[3] = abi.encodeWithSelector(
            EtherFiOperationParameters.updateTagKeyValue.selector,
            _PRIORITY_WITHDRAWAL,
            "AUTO_FULFILL_LIMIT_ETH",
            "5000"
        );
        data[4] = abi.encodeWithSelector(
            EtherFiOperationParameters.updateTagKeyValue.selector,
            _PRIORITY_WITHDRAWAL,
            "DAILY_CAP_PER_USER_ETH",
            "10000"
        );
        data[5] = abi.encodeWithSelector(
            EtherFiOperationParameters.updateTagKeyValue.selector,
            _PRIORITY_WITHDRAWAL,
            "WEEKLY_CAP_PER_USER_ETH",
            "50000"
        );
        data[6] = abi.encodeWithSelector(
            EtherFiOperationParameters.updateTagKeyValue.selector,
            _PRIORITY_WITHDRAWAL,
            "FINALIZED_NOT_CLAIMED_EXPIRY_DAYS",
            "5"
        );
        data[7] = abi.encodeWithSelector(
            EtherFiOperationParameters.updateTagKeyValue.selector,
            _PRIORITY_WITHDRAWAL,
            "ESTIMATED_WD_TIME",
            _ESTIMATED_WD_TIME_SECONDS
        );
        data[8] = abi.encodeWithSelector(
            EtherFiOperationParameters.updateTagKeyValue.selector,
            _PRIORITY_USERS_FEE_BPS,
            _TEST_PRIORITY_USER,
            "100"
        );

        writeSafeJson(
            "script/upgrades/priority-queue",
            "set-priority-queue-params.json",
            ETHERFI_OPERATING_ADMIN,
            targets,
            values,
            data,
            1
        );
    }
}
