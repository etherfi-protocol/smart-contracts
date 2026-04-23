// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "forge-std/Script.sol";
import {IPriorityWithdrawalQueue} from "../../../src/interfaces/IPriorityWithdrawalQueue.sol";
import {ILiquidityPool} from "../../../src/interfaces/ILiquidityPool.sol";
import {IeETH} from "../../../src/interfaces/IeETH.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Utils} from "../../utils/utils.sol";
import {Deployed} from "../../deploys/Deployed.s.sol";

interface IEtherFiOperationParameters {
    function updateTagKeyValue(string memory tag, string memory key, string memory value) external;
}

/**
 * @title WhitelistUsers
 * @notice Generates a batched Safe JSON that:
 *         1. Whitelists user addresses on the PriorityWithdrawalQueue
 *         2. Sets PRIORITY_USERS_FEE_BPS for USER_2 on EtherFiOperationParameters
 *         Also runs fork tests to verify the whitelisted users can deposit and request withdrawals.
 *
 * Usage:
 *   forge script script/operations/priority-queue/WhitelistUsers.s.sol --fork-url $MAINNET_RPC_URL -vvvv
 */
contract WhitelistUsers is Script, Deployed, Utils {
    address constant USER_1 = 0xf0bb20865277aBd641a307eCe5Ee04E79073416C;
    address constant USER_2 = 0xa0Ff21485e85d09eE3E59bc8Fa15a099E1C1a413;

    function run() public {
        // --- Tx 1: Whitelist users on PriorityWithdrawalQueue ---
        address[] memory whitelistUsers = new address[](2);
        whitelistUsers[0] = USER_1;
        whitelistUsers[1] = USER_2;

        bool[] memory statuses = new bool[](2);
        statuses[0] = true;
        statuses[1] = true;

        bytes memory whitelistCallData = abi.encodeWithSelector(
            IPriorityWithdrawalQueue.batchUpdateWhitelist.selector,
            whitelistUsers,
            statuses
        );

        // --- Tx 2: Set fee BPS for USER_2 on EtherFiOperationParameters ---
        bytes memory feeCallData = abi.encodeWithSelector(
            IEtherFiOperationParameters.updateTagKeyValue.selector,
            "PRIORITY_USERS_FEE_BPS",
            vm.toString(USER_2),
            "10"
        );

        // --- Build batch Safe JSON ---
        address[] memory targets = new address[](2);
        uint256[] memory values = new uint256[](2);
        bytes[] memory calldatas = new bytes[](2);

        targets[0] = PRIORITY_WITHDRAWAL_QUEUE;
        values[0] = 0;
        calldatas[0] = whitelistCallData;

        targets[1] = ETHERFI_OPERATION_PARAMETERS;
        values[1] = 0;
        calldatas[1] = feeCallData;

        console2.log("=== Tx 1: PriorityWithdrawalQueue Whitelist ===");
        console2.log("Target:", targets[0]);
        console2.log("Calldata:");
        console2.logBytes(calldatas[0]);

        console2.log("");
        console2.log("=== Tx 2: EtherFiOperationParameters Fee BPS ===");
        console2.log("Target:", targets[1]);
        console2.log("Calldata:");
        console2.logBytes(calldatas[1]);

        console2.log("");
        console2.log("=== Writing Batched Safe JSON ===");
        writeSafeJson(
            "script/operations/priority-queue",
            "whitelist-users.json",
            ETHERFI_OPERATING_ADMIN,
            targets,
            values,
            calldatas,
            block.chainid
        );

        // Execute on fork and run tests
        console2.log("");
        console2.log("=== Fork Tests ===");
        _executeOnFork(whitelistUsers, statuses);
        _testDepositAndRequest();
        console2.log("All fork tests passed!");
    }

    function _executeOnFork(address[] memory users, bool[] memory statuses) internal {
        vm.prank(ETHERFI_OPERATING_ADMIN);
        IPriorityWithdrawalQueue(PRIORITY_WITHDRAWAL_QUEUE).batchUpdateWhitelist(users, statuses);

        vm.prank(ETHERFI_OPERATING_ADMIN);
        IEtherFiOperationParameters(ETHERFI_OPERATION_PARAMETERS).updateTagKeyValue(
            "PRIORITY_USERS_FEE_BPS",
            vm.toString(USER_2),
            "10"
        );
        console2.log("[OK] Fee BPS set for USER_2");

        require(IPriorityWithdrawalQueue(PRIORITY_WITHDRAWAL_QUEUE).isWhitelisted(USER_1), "user1 not whitelisted");
        require(IPriorityWithdrawalQueue(PRIORITY_WITHDRAWAL_QUEUE).isWhitelisted(USER_2), "user2 not whitelisted");
        console2.log("[OK] Both users whitelisted");
    }

    function _testDepositAndRequest() internal {
        ILiquidityPool lp = ILiquidityPool(payable(LIQUIDITY_POOL));
        IPriorityWithdrawalQueue pq = IPriorityWithdrawalQueue(PRIORITY_WITHDRAWAL_QUEUE);

        // Fund users with ETH and deposit to get eETH
        uint256 depositAmount = 10 ether;
        vm.deal(USER_1, depositAmount);
        vm.deal(USER_2, depositAmount);

        vm.prank(USER_1);
        lp.deposit{value: depositAmount}();

        vm.prank(USER_2);
        lp.deposit{value: depositAmount}();

        require(IERC20(EETH).balanceOf(USER_1) > 0, "user1 has no eETH");
        require(IERC20(EETH).balanceOf(USER_2) > 0, "user2 has no eETH");
        console2.log("[OK] Both users deposited ETH and received eETH");

        // User1 requests 1 ETH withdrawal
        uint96 amount1 = 1 ether;
        uint96 shares1 = uint96(lp.sharesForAmount(amount1));
        uint96 minOut1 = uint96(lp.amountForShare(shares1));

        vm.startPrank(USER_1);
        IERC20(EETH).approve(PRIORITY_WITHDRAWAL_QUEUE, amount1);
        bytes32 reqId1 = pq.requestWithdraw(amount1, minOut1);
        vm.stopPrank();
        require(reqId1 != bytes32(0), "user1 requestId is zero");
        console2.log("[OK] User1 requested 1 ETH withdrawal, requestId:");
        console2.logBytes32(reqId1);

        // User2 requests 2 ETH withdrawal
        uint96 amount2 = 2 ether;
        uint96 shares2 = uint96(lp.sharesForAmount(amount2));
        uint96 minOut2 = uint96(lp.amountForShare(shares2));

        vm.startPrank(USER_2);
        IERC20(EETH).approve(PRIORITY_WITHDRAWAL_QUEUE, amount2);
        bytes32 reqId2 = pq.requestWithdraw(amount2, minOut2);
        vm.stopPrank();
        require(reqId2 != bytes32(0), "user2 requestId is zero");
        require(reqId1 != reqId2, "request IDs collided");
        console2.log("[OK] User2 requested 2 ETH withdrawal, requestId:");
        console2.logBytes32(reqId2);

        require(pq.ethAmountLockedForPriorityWithdrawal() > 0, "no ETH locked for priority withdrawals");
        console2.log("[OK] ETH locked for priority withdrawals:", pq.ethAmountLockedForPriorityWithdrawal());
    }
}
