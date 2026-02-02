// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../../../src/RestakingRewardsRouter.sol";
import "../../../src/interfaces/IRoleRegistry.sol";
import "../../utils/utils.sol";

// forge script script/operations/restaking-router/ConfigureRestakingRewardsRouter.s.sol --fork-url $MAINNET_RPC_URL -vvvv
contract ConfigureRestakingRewardsRouter is Script, Utils {
    bytes32 constant ETHERFI_REWARDS_ROUTER_ADMIN_ROLE =
        keccak256("ETHERFI_REWARDS_ROUTER_ADMIN_ROLE");
    bytes32 constant ETHERFI_REWARDS_ROUTER_ERC20_TRANSFER_ROLE =
        keccak256("ETHERFI_REWARDS_ROUTER_ERC20_TRANSFER_ROLE");

    address constant SELINI_MARKET_MAKER = 0x0B7178f2f1f44Cae3aed801c21D589CbAb458118;

    EtherFiTimelock etherFiTimelock = EtherFiTimelock(payable(UPGRADE_TIMELOCK));

    function run() public {
        console2.log("================================================");
        console2.log("== Configure RestakingRewardsRouter Roles ==");
        console2.log("================================================");
        console2.log("");

        address[] memory targets = new address[](2);
        bytes[] memory data = new bytes[](2);
        uint256[] memory values = new uint256[](2);

        // Grant ETHERFI_REWARDS_ROUTER_ADMIN_ROLE to Operating Admin (multisig)
        targets[0] = ROLE_REGISTRY;
        data[0] = _encodeRoleGrant(ETHERFI_REWARDS_ROUTER_ADMIN_ROLE, ETHERFI_OPERATING_ADMIN);

        // Grant ETHERFI_REWARDS_ROUTER_ERC20_TRANSFER_ROLE to Admin EOA
        targets[1] = ROLE_REGISTRY;
        data[1] = _encodeRoleGrant(ETHERFI_REWARDS_ROUTER_ERC20_TRANSFER_ROLE, ADMIN_EOA);

        bytes32 timelockSalt = keccak256(abi.encode(targets, data, block.number));

        // schedule
        bytes memory scheduleCalldata = abi.encodeWithSelector(
            etherFiTimelock.scheduleBatch.selector,
            targets,
            values,
            data,
            bytes32(0), // predecessor
            timelockSalt,
            MIN_DELAY_TIMELOCK
        );

        console2.log("====== Schedule Role Grants Tx:");
        console2.logBytes(scheduleCalldata);
        console2.log("================================================");
        console2.log("");

        // execute
        bytes memory executeCalldata = abi.encodeWithSelector(
            etherFiTimelock.executeBatch.selector,
            targets,
            values,
            data,
            bytes32(0), // predecessor
            timelockSalt
        );

        console2.log("====== Execute Role Grants Tx:");
        console2.logBytes(executeCalldata);
        console2.log("================================================");
        console2.log("");

        // uncomment to run against fork
        // vm.startBroadcast(ETHERFI_UPGRADE_ADMIN);
        vm.startPrank(ETHERFI_UPGRADE_ADMIN);
        etherFiTimelock.scheduleBatch(targets, values, data, bytes32(0), timelockSalt, MIN_DELAY_TIMELOCK);
        console2.log("====== Role Grants Scheduled Successfully");
        console2.log("================================================");
        console2.log("");
        vm.warp(block.timestamp + MIN_DELAY_TIMELOCK + 1);
        etherFiTimelock.executeBatch(targets, values, data, bytes32(0), timelockSalt);
        vm.stopPrank();

        console2.log("====== Role Grants Executed Successfully");
        console2.log("================================================");
        console2.log("");

        vm.prank(ETHERFI_OPERATING_ADMIN);
        RestakingRewardsRouter(payable(RESTAKING_REWARDS_ROUTER)).setRecipientAddress(SELINI_MARKET_MAKER);

        //--------------------------------------------------------------------------------------
        //-------------- Set Recipient Address (via Operating Admin Multisig) --------------
        //--------------------------------------------------------------------------------------

        // Calldata for Operating Admin multisig to call setRecipientAddress
        bytes memory setRecipientCalldata = abi.encodeWithSelector(
            RestakingRewardsRouter.setRecipientAddress.selector,
            SELINI_MARKET_MAKER
        );

        console2.log("====== setRecipientAddress Calldata (Operating Admin Multisig):");
        console2.log("Target: %s", address(RESTAKING_REWARDS_ROUTER));
        console2.logBytes(setRecipientCalldata);
        console2.log("================================================");
        console2.log("");
    }

    function _encodeRoleGrant(bytes32 role, address account) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(IRoleRegistry.grantRole.selector, role, account);
    }
}
