// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "./TestSetup.sol";
import "../src/EtherFiTimelock.sol";
import "forge-std/console2.sol";

contract TimelockTest is TestSetup {

    function test_timelock() public {
        initializeRealisticFork(MAINNET_FORK);

        address owner = managerInstance.owner();
        address admin = vm.addr(0x1234);
        console2.log("adminAddr:", admin);
        console2.log("ownerAddr:", owner);

        // who can propose transactions for the timelock
        address[] memory proposers = new address[](2);
        proposers[0] = owner;
        proposers[1] = admin;

        // who can execute transactions for the timelock
        address[] memory executors = new address[](1);
        executors[0] = owner;

        EtherFiTimelock tl = new EtherFiTimelock(2 days, proposers, executors, address(0x0));

        // transfer ownership to new timelock
        vm.prank(owner);
        managerInstance.transferOwnership(address(tl));
        assertEq(managerInstance.owner(), address(tl));

        // attempt to call an onlyOwner function with the previous owner
        vm.prank(owner);
        vm.expectRevert("Ownable: caller is not the owner");
        managerInstance.updateAdmin(admin, true);

        // encoded data for EtherFiNodesManager.UpdateAdmin(admin, true)
        bytes memory data = hex"670a6fd9000000000000000000000000cf03dd0a894ef79cb5b601a43c4b25e3ae4c67ed0000000000000000000000000000000000000000000000000000000000000001";

        // attempt to directly execute with timelock. Not allowed to do tx before queuing it
        vm.prank(owner);
        vm.expectRevert("TimelockController: operation is not ready");
        tl.execute(
            address(managerInstance), // target
            0,                        // value
            data,                     // encoded call data
            0,                        // optional predecessor
            0                         // optional salt
        );

        // not allowed to schedule a tx below the minimum delay
        vm.prank(owner);
        vm.expectRevert("TimelockController: insufficient delay");
        tl.schedule(
            address(managerInstance), // target
            0,                        // value
            data,                     // encoded call data
            0,                        // optional predecessor
            0,                        // optional salt
            1 days                    // time before operation can be run
        );

        // schedule updateAdmin tx
        vm.prank(owner);
        tl.schedule(
            address(managerInstance), // target
            0,                        // value
            data,                     // encoded call data
            0,                        // optional predecessor
            0,                        // optional salt
            2 days                    // time before operation can be run
        );

        // find operation id by hashing relevant data
        bytes32 operationId = tl.hashOperation(address(managerInstance), 0, data, 0, 0);

        // cancel the scheduled tx
        vm.prank(owner);
        tl.cancel(operationId);

        // wait 2 days
        vm.warp(block.timestamp + 2 days);

        // should be unable to execute cancelled tx
        vm.prank(owner);
        vm.expectRevert("TimelockController: operation is not ready");
        tl.execute(
            address(managerInstance), // target
            0,                        // value
            data,                     // encoded call data
            0,                        // optional predecessor
            0                         // optional salt
        );

        // schedule again and wait
        vm.prank(owner);
        tl.schedule(
            address(managerInstance), // target
            0,                        // value
            data,                     // encoded call data
            0,                        // optional predecessor
            0,                        // optional salt
            2 days                    // time before operation can be run
        );
        vm.warp(block.timestamp + 2 days);

        // account with admin but not exec should not be able to execute
        vm.prank(admin);
        vm.expectRevert("AccessControl: account 0xcf03dd0a894ef79cb5b601a43c4b25e3ae4c67ed is missing role 0xd8aa0f3194971a2a116679f7c2090f6939c8d4e01a2a8d7e41d55e5351469e63");
        tl.execute(
            address(managerInstance), // target
            0,                        // value
            data,                     // encoded call data
            0,                        // optional predecessor
            0                         // optional salt
        );

        // exec account should be able to execute tx
        vm.prank(owner);
        tl.execute(
            address(managerInstance), // target
            0,                        // value
            data,                     // encoded call data
            0,                        // optional predecessor
            0                         // optional salt
        );

        // admin account should now have admin permissions on EtherfiNodesManager
        assertEq(managerInstance.admins(admin), true);

        // queue and execute a tx to undo that change
        bytes memory undoData = hex"670a6fd9000000000000000000000000cf03dd0a894ef79cb5b601a43c4b25e3ae4c67ed0000000000000000000000000000000000000000000000000000000000000000";
        vm.prank(admin);
        tl.schedule(
            address(managerInstance), // target
            0,                        // value
            undoData,                 // encoded call data
            0,                        // optional predecessor
            0,                        // optional salt
            2 days                    // time before operation can be run
        );
        vm.warp(block.timestamp + 2 days);
        vm.prank(owner);
        tl.execute(
            address(managerInstance), // target
            0,                        // value
            undoData,                 // encoded call data
            0,                        // optional predecessor
            0                         // optional salt
        );
        assertEq(managerInstance.admins(admin), false);

        // non-proposer should not be able to schedule tx
        address rando = vm.addr(0x987654321);
        vm.prank(rando);
        vm.expectRevert("AccessControl: account 0xda5b629bd4e25a31b51a5bb22c55a39ec7efd68c is missing role 0xb09aa5aeb3702cfd50b6b62bc4532604938f21248a27a1d5ca736082b6819cc1");
        tl.schedule(
            address(managerInstance), // target
            0,                        // value
            undoData,                 // encoded call data
            0,                        // optional predecessor
            0,                        // optional salt
            2 days                    // time before operation can be run
        );


        console2.log("roleadmin:");
        console2.logBytes32( tl.getRoleAdmin(keccak256("PROPOSER_ROLE")));

        // should be able to give proposer role to new address. Now previous tx should work
        // I use different salt because we already previously scheduled a tx with this data and salt 0
        vm.prank(address(tl));
        tl.grantRole(keccak256("PROPOSER_ROLE"), rando);

        vm.prank(rando);
        tl.schedule(
            address(managerInstance), // target
            0,                        // value
            undoData,                 // encoded call data
            0,                        // optional predecessor
            bytes32(uint256(1)),       // optional salt
            2 days                    // time before operation can be run
        );

        // Timelock should be able to give control back to a normal account
        address newOwner = 0xF155a2632Ef263a6A382028B3B33feb29175b8A5;
        bytes memory transferOwershipData = hex"f2fde38b000000000000000000000000f155a2632ef263a6a382028b3b33feb29175b8a5";
        vm.prank(admin);
        tl.schedule(
            address(managerInstance), // target
            0,                        // value
            transferOwershipData,     // encoded call data
            0,                        // optional predecessor
            0,                        // optional salt
            2 days                    // time before operation can be run
        );
        vm.warp(block.timestamp + 2 days);
        vm.prank(owner);
        tl.execute(
            address(managerInstance), // target
            0,                        // value
            transferOwershipData,                 // encoded call data
            0,                        // optional predecessor
            0                         // optional salt
        );
        assertEq(managerInstance.owner(), newOwner);
    }

    function test_generate_EtherFiOracle_updateAdmin() public {
        emit Schedule(address(etherFiOracleInstance), 0, abi.encodeWithSelector(bytes4(keccak256("updateAdmin(address,bool)")), 0x2aCA71020De61bb532008049e1Bd41E451aE8AdC, true), bytes32(0), bytes32(0), 259200);
    }

    function test_registerToken() public {
        initializeRealisticFork(MAINNET_FORK);
        address target = address(liquifierInstance);

        {
            // MODE
            bytes memory data = abi.encodeWithSelector(Liquifier.registerToken.selector, 0xDc400f3da3ea5Df0B7B6C127aE2e54CE55644CF3, address(0), true, 0, 2_000, 10_000, true);
            _execute_timelock(target, data, false, false, true, true);
        }
        {
            // LINEA
            bytes memory data = abi.encodeWithSelector(Liquifier.registerToken.selector, 0x61Ff310aC15a517A846DA08ac9f9abf2A0f9A2bf, address(0), true, 0, 2_000, 10_000, true);
            _execute_timelock(target, data, false, false, true, true);
        }
    }

    function test_updateDepositCap() public {
        initializeRealisticFork(MAINNET_FORK);
        address target = address(liquifierInstance);
        // {
        //     bytes memory data = abi.encodeWithSelector(Liquifier.updateDepositCap.selector, 0x83998e169026136760bE6AF93e776C2F352D4b28, 4_000, 20_000);
        //     _execute_timelock(target, data, false, false, true, true);
        // }
        // {
        //     bytes memory data = abi.encodeWithSelector(Liquifier.updateDepositCap.selector, 0xDc400f3da3ea5Df0B7B6C127aE2e54CE55644CF3, 4_000, 20_000);
        //     _execute_timelock(target, data, false, false, true, true);
        // }
        // {
        //     bytes memory data = abi.encodeWithSelector(Liquifier.updateDepositCap.selector, 0x0295E0CE709723FB25A28b8f67C54a488BA5aE46, 1_000, 100_000);
        //     _execute_timelock(target, data, true, true, true, false);
        // }
        // {
        //     bytes memory data = abi.encodeWithSelector(Liquifier.updateDepositCap.selector, 0xDc400f3da3ea5Df0B7B6C127aE2e54CE55644CF3, 1_000, 100_000);
        //     _execute_timelock(target, data, true, true, true, false);
        // }

        // {
        //     // LINEA
        //     bytes memory data = abi.encodeWithSelector(Liquifier.updateDepositCap.selector, 0x61Ff310aC15a517A846DA08ac9f9abf2A0f9A2bf, 2_000, 10_000);
        //     _execute_timelock(target, data, false);
        // }
        // {
        //     // BASE
        //     bytes memory data = abi.encodeWithSelector(Liquifier.updateDepositCap.selector, 0x0295E0CE709723FB25A28b8f67C54a488BA5aE46, 2_000, 10_000);
        //     _execute_timelock(target, data, false);
        // }
    }
}

// {"version":"1.0","chainId":"1